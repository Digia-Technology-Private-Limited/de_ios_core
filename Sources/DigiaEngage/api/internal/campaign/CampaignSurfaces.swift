import Foundation

// One ``CampaignSurface`` per kind, in the order the SDK asks them. Each holds
// its kind's branch of what used to be a switch in ``SDKInstance`` —
// `surfaceOccupants`, `settleSuperseded`, `dismissSurfaces(for:)` and
// `startCampaign` — moved verbatim; only the receiver changed.
//
// They are separate classes (not extensions) because A2 gives each surface
// its own reporter next to its orchestrator; the state they read — the nudge
// overlay, survey tokens, the emitter — still lives on the SDK for now.
//
// Mirrors Flutter's `campaign_surfaces.dart` (PR #252), adapted for the
// iOS-only pieces: the classic-RN external guide, `presentationId`-stamped
// delivery matching, and the floater busy-surface detail.

/// The SDK's one logging style — see ``DigiaLogger``.
private let surfaceLog = DigiaLogger()

/// Whether `other` is the delivery `payload` identifies: same CEP campaign,
/// and either `payload` is unstamped (a live test's synthesised payload) or
/// the presentation ids match, so a teardown firing late can't take down a
/// newer delivery of the same campaign (SR60). Shared by every surface's
/// `dismiss`, exactly as `dismissSurfaces(for:)` matched before.
func surfaceOwns(_ other: CEPTriggerPayload?, payload: CEPTriggerPayload) -> Bool {
    guard let other, other.cepCampaignId == payload.cepCampaignId else { return false }
    return payload.presentationId == nil || other.presentationId == payload.presentationId
}

final class NudgeCampaignSurface: CampaignSurface {
    init(_ sdk: SDKInstance) { self.sdk = sdk }

    private unowned let sdk: SDKInstance

    func start(_ request: CampaignRequest, _ nudgeConfig: NudgeConfig) -> RoutingVerdict {
        // Resolve variable context: dashboard schemas define type + fallback;
        // CEP trigger variables win over fallbacks (D3′).
        let variableContext = buildVariableContext(
            schemas: nudgeConfig.variableSchemas,
            cepVars: request.payload.variables
        )
        sdk.controller.showNudge(
            DigiaNudgePresentation(
                config: nudgeConfig,
                payload: request.payload,
                variables: variableContext.values.isEmpty && variableContext.types.isEmpty
                    ? nil : variableContext
            ))
        return .accepted(payload: request.payload, kind: .modal)
    }

    var occupants: [SurfaceOccupant] {
        guard let nudge = sdk.controller.activeNudge else { return [] }
        return [sdk.occupant(.nudge, nudge.payload)]
    }

    func supersede(_ occupant: SurfaceOccupant) {
        guard occupant.kind == .nudge else { return }
        guard let nudge = sdk.controller.activeNudge,
            nudge.payload.cepCampaignId == occupant.cepCampaignId
        else { return }
        if sdk.dwellTracker.elapsedMs(occupant.cepCampaignId) != nil {
            sdk.nudgeOrchestrator.markNudgeDismissed(reason: .superseded)
        } else {
            sdk.controller.dismissNudge()
            _ = sdk.dwellTracker.consumeDwellMs(occupant.cepCampaignId)
            sdk.events.toCep(.dismissed(reason: .superseded), payload: nudge.payload)
        }
    }

    func dismiss(_ payload: CEPTriggerPayload) {
        guard surfaceOwns(sdk.controller.activeNudge?.payload, payload: payload) else { return }
        // A CEP cancel of a nudge on screen ends it like any close: Digia gets its Dismissed(cancelled),
        // and the CEP the same outcome. A watchdog's teardown reaches here already settled, unseen, and
        // stays silent.
        if sdk.coordinator.ownerOf(payload)?.state == .displaying {
            sdk.nudgeOrchestrator.markNudgeDismissed(reason: .cancelled)
        } else {
            sdk.controller.dismissNudge()
        }
    }
}

final class SurveySurface: CampaignSurface {
    init(_ sdk: SDKInstance) { self.sdk = sdk }

    private unowned let sdk: SDKInstance

    func start(_ request: CampaignRequest, _ config: SurveyConfigModel) -> RoutingVerdict {
        guard sdk.surveyOrchestrator.start(payload: request.payload, config: config) else {
            return request.invalidConfig("survey could not start", cause: "start_failed")
        }
        return .accepted(payload: request.payload, kind: .modal)
    }

    var occupants: [SurfaceOccupant] {
        guard let survey = sdk.surveyOrchestrator.state else { return [] }
        return [sdk.occupant(.survey, survey.payload)]
    }

    func supersede(_ occupant: SurfaceOccupant) {
        guard occupant.kind == .survey else { return }
        guard let state = sdk.surveyOrchestrator.state,
            state.payload.cepCampaignId == occupant.cepCampaignId
        else { return }
        if sdk.dwellTracker.elapsedMs(occupant.cepCampaignId) != nil {
            // R3-D5 (SR69): the fields a user close sends, from the renderer.
            let progress = sdk.surveyOrchestrator.progress()
            sdk.surveyReporter.markSurveyDismissed(
                abandonedAtItem: progress?.abandonedAtItem,
                answeredCount: progress?.answeredCount,
                reason: .superseded
            )
        } else {
            sdk.surveyOrchestrator.dismiss()
            _ = sdk.dwellTracker.consumeDwellMs(occupant.cepCampaignId)
            sdk.surveyReporter.clearQuestionViewedAt(token: state.token)
            sdk.events.toCep(.dismissed(reason: .superseded), payload: state.payload)
        }
    }

    func dismiss(_ payload: CEPTriggerPayload) {
        guard surfaceOwns(sdk.surveyOrchestrator.state?.payload, payload: payload) else { return }
        sdk.surveyOrchestrator.dismiss()
    }
}

final class GuideSurface: CampaignSurface {
    init(_ sdk: SDKInstance) { self.sdk = sdk }

    private unowned let sdk: SDKInstance

    func start(_ request: CampaignRequest, _ guideConfig: GuideConfigModel) -> RoutingVerdict {
        let campaign = request.campaign
        let payload = request.payload
        let key = campaign.campaignKey
        if sdk.isClassicRNGuide(guideConfig) {
            guard let renderViaJs = sdk.onGuideRenderRequest else {
                let message = "React Native guide renderer is not registered"
                request.driver.policy.onDropped(DropReason.hostNotMounted, message)
                sdk.logNativeGuideStage("route", "result=dropped reason=js_renderer_missing campaign_key=\(key)")
                return .dropped(reason: .hostNotMounted, detail: message)
            }
            sdk.activeExternalGuide = SDKInstance.ExternalGuide(campaign: campaign, payload: payload)
            // `payload` was stamped by `coordinator.open()` before routing
            // ever saw it, so this is only ever empty for a delivery that
            // bypassed that stamp — a live test's synthesised payload. The
            // fallback is a harmless dead id rather than a crash: it simply
            // never resolves in `reportExternalGuideLifecycle`.
            renderViaJs(
                GuideRenderRequest(
                    payload: payload,
                    presentationId: payload.presentationId ?? "",
                    campaignId: campaign.id,
                    templateConfigJson: campaign.guideTemplateJson
                )
            )
            return .accepted(payload: payload, kind: .modal)
        }
        // As Flutter: skip steps with no canvas, and show the rest.
        var canvasGuide = guideConfig
        canvasGuide.steps = guideConfig.steps.filter { $0.widgetConfig.canvas != nil }
        // The surface rule has cleared the screen, so a refusal here is the
        // campaign itself (not a parsed guide), never another guide.
        var canvasCampaign = campaign
        canvasCampaign.config = .guide(canvasGuide)
        guard sdk.guideOrchestrator.start(canvasCampaign, payload: payload) else {
            sdk.logNativeGuideStage("route", "result=dropped reason=invalid_config campaign_key=\(key)")
            return request.invalidConfig("guide could not start", cause: "start_failed")
        }
        sdk.guideOrchestrator.guideCompletionFired = false
        sdk.logNativeGuideStage("route", "result=accepted campaign_key=\(key)")
        return .accepted(payload: payload, kind: .modal)
    }

    var occupants: [SurfaceOccupant] {
        var result: [SurfaceOccupant] = []
        if let guide = sdk.guideOrchestrator.state {
            result.append(sdk.occupant(.guide, guide.payload))
        }
        if let external = sdk.activeExternalGuide {
            result.append(sdk.occupant(.guide, external.payload))
        }
        return result
    }

    func supersede(_ occupant: SurfaceOccupant) {
        guard occupant.kind == .guide else { return }
        if let state = sdk.guideOrchestrator.state,
            state.payload.cepCampaignId == occupant.cepCampaignId
        {
            if sdk.dwellTracker.elapsedMs(occupant.cepCampaignId) != nil {
                // No `completed:` override, so a completion the CTA already
                // fired wins (R3-02, R4-D2): CEP `completed`, no Digia dismiss.
                sdk.guideOrchestrator.dismissGuide(reason: .superseded)
            } else {
                sdk.guideOrchestrator.dismiss()
                _ = sdk.dwellTracker.consumeDwellMs(occupant.cepCampaignId)
                sdk.guideOrchestrator.guideCompletionFired = false
                sdk.guideOrchestrator.pendingGuideDismissReason = nil
                sdk.events.toCep(.dismissed(reason: .superseded), payload: state.payload)
            }
        } else if let external = sdk.activeExternalGuide,
            external.payload.cepCampaignId == occupant.cepCampaignId
        {
            sdk.activeExternalGuide = nil
            sdk.events.toCep(.dismissed(reason: .superseded), payload: external.payload)
        }
    }

    func dismiss(_ payload: CEPTriggerPayload) {
        if surfaceOwns(sdk.activeExternalGuide?.payload, payload: payload) {
            sdk.activeExternalGuide = nil
        }
        if surfaceOwns(sdk.guideOrchestrator.state?.payload, payload: payload) {
            sdk.guideOrchestrator.dismissIfActive(payloadId: payload.cepCampaignId)
        }
    }
}

final class PipSurface: CampaignSurface {
    init(_ sdk: SDKInstance) { self.sdk = sdk }

    private unowned let sdk: SDKInstance

    func start(_ request: CampaignRequest) -> RoutingVerdict {
        let campaign = request.campaign
        let payload = request.payload
        let key = campaign.campaignKey
        let started = sdk.floaterOrchestrator.start(campaign, payload: payload, screenName: sdk.currentScreenForAnchorless)
        let failure = sdk.floaterOrchestrator.lastStartFailureReason
        let failedBusy = sdk.floaterOrchestrator.lastStartFailedBusy
        var busyDetail: [String: Any] = [:]
        guard started else {
            let message = failure ?? "floater start failed"
            surfaceLog.d("Dropped — floater not started (reason=\(failure ?? "unknown"))", campaign: key)
            // Another floater on screen is a busy surface, not a broken campaign.
            if failedBusy {
                request.driver.policy.onDropped(DropReason.surfaceBusy, message)
                busyDetail = floaterBusyDetail() ?? [:]
                return .dropped(reason: .surfaceBusy, detail: message, deliveryDetail: busyDetail)
            }
            return request.invalidConfig(message, cause: "start_failed")
        }
        return .accepted(payload: payload, kind: .floating)
    }

    private func floaterBusyDetail() -> [String: Any]? {
        guard let floater = sdk.floaterOrchestrator.state else { return nil }
        let blocker = sdk.occupant(
            sdk.floaterOrchestrator.surface == .expanded ? .floaterExpanded : .floaterCollapsed,
            floater.payload)
        return CampaignRouter.surfaceBusyDetail(blocker, campaignId: sdk.campaignStore.find(blocker.campaignKey)?.id)
    }

    var occupants: [SurfaceOccupant] {
        guard let floater = sdk.floaterOrchestrator.state, !sdk.floaterOrchestrator.closing else { return [] }
        return [sdk.occupant(
            sdk.floaterOrchestrator.surface == .expanded ? .floaterExpanded : .floaterCollapsed,
            floater.payload)]
    }

    func supersede(_ occupant: SurfaceOccupant) {
        guard occupant.kind == .floaterExpanded || occupant.kind == .floaterCollapsed else { return }
        if sdk.floaterOrchestrator.state?.payload.cepCampaignId == occupant.cepCampaignId {
            sdk.floaterOrchestrator.dismiss(.superseded)
        }
    }

    func dismiss(_ payload: CEPTriggerPayload) {
        guard surfaceOwns(sdk.floaterOrchestrator.state?.payload, payload: payload) else { return }
        sdk.floaterOrchestrator.dismiss(.invalidated)
    }
}

final class FloaterStorySurface: CampaignSurface {
    init(_ sdk: SDKInstance) { self.sdk = sdk }

    private unowned let sdk: SDKInstance

    func start(_ request: CampaignRequest) -> RoutingVerdict {
        let campaign = request.campaign
        let payload = request.payload
        let key = campaign.campaignKey
        let started = sdk.floaterStoryOrchestrator.start(
            campaign, payload: payload, screenName: sdk.currentScreenForAnchorless)
        let failure = sdk.floaterStoryOrchestrator.lastStartFailureReason
        let failedBusy = sdk.floaterStoryOrchestrator.lastStartFailedBusy
        var busyDetail: [String: Any] = [:]
        guard started else {
            let message = failure ?? "floater start failed"
            surfaceLog.d("Dropped — floater not started (reason=\(failure ?? "unknown"))", campaign: key)
            // Another floater on screen is a busy surface, not a broken campaign.
            if failedBusy {
                request.driver.policy.onDropped(DropReason.surfaceBusy, message)
                busyDetail = storyBusyDetail() ?? [:]
                return .dropped(reason: .surfaceBusy, detail: message, deliveryDetail: busyDetail)
            }
            return request.invalidConfig(message, cause: "start_failed")
        }
        return .accepted(payload: payload, kind: .floating)
    }

    private func storyBusyDetail() -> [String: Any]? {
        guard let story = sdk.floaterStoryOrchestrator.state else { return nil }
        let blocker = sdk.occupant(
            sdk.floaterStoryOrchestrator.storyOverlayActive ? .floaterExpanded : .floaterCollapsed,
            story.payload)
        return CampaignRouter.surfaceBusyDetail(blocker, campaignId: sdk.campaignStore.find(blocker.campaignKey)?.id)
    }

    var occupants: [SurfaceOccupant] {
        guard let story = sdk.floaterStoryOrchestrator.state, !sdk.floaterStoryOrchestrator.closing else { return [] }
        // An open story is the story floater's expanded state.
        return [sdk.occupant(
            sdk.floaterStoryOrchestrator.storyOverlayActive ? .floaterExpanded : .floaterCollapsed,
            story.payload)]
    }

    func supersede(_ occupant: SurfaceOccupant) {
        guard occupant.kind == .floaterExpanded || occupant.kind == .floaterCollapsed else { return }
        if sdk.floaterStoryOrchestrator.state?.payload.cepCampaignId == occupant.cepCampaignId {
            sdk.floaterStoryOrchestrator.dismiss(.superseded)
        }
    }

    func dismiss(_ payload: CEPTriggerPayload) {
        guard surfaceOwns(sdk.floaterStoryOrchestrator.state?.payload, payload: payload) else { return }
        sdk.floaterStoryOrchestrator.dismiss(.invalidated)
    }
}

final class InlineSurface: CampaignSurface {
    init(_ sdk: SDKInstance) { self.sdk = sdk }

    private unowned let sdk: SDKInstance

    func startCarousel(_ request: CampaignRequest, _ config: InlineCarouselConfig) -> RoutingVerdict {
        sdk.inlineController.setCarouselConfig(config.slotKey, config: config)
        sdk.inlineController.setCampaign(config.slotKey, payload: request.payload)
        return inlineRouted(request)
    }

    func startBanner(_ request: CampaignRequest, _ config: InlineBannerConfig) -> RoutingVerdict {
        sdk.inlineController.setBannerConfig(config.slotKey, config: config)
        sdk.inlineController.setCampaign(config.slotKey, payload: request.payload)
        return inlineRouted(request)
    }

    func startCanvas(_ request: CampaignRequest, _ config: InlineCanvasConfig) -> RoutingVerdict {
        sdk.inlineController.setCanvasConfig(config.slotKey, config: config)
        sdk.inlineController.setCampaign(config.slotKey, payload: request.payload)
        return inlineRouted(request)
    }

    func startStory(_ request: CampaignRequest, _ config: InlineStoryConfig) -> RoutingVerdict {
        sdk.inlineController.setStoryConfig(config.slotKey, config: config)
        sdk.inlineController.setCampaign(config.slotKey, payload: request.payload)
        return inlineRouted(request)
    }

    private func inlineRouted(_ request: CampaignRequest) -> RoutingVerdict {
        // No synchronous way to know a matching DigiaSlot exists anywhere in
        // the app, so a live test's own watchdog stands in for the anchor
        // check a guide gets — this only narrows its verdict to the inline
        // one. reportSlotFirstRender's shown ACK wins the race if a slot
        // renders first (LiveTestContext is idempotent).
        if let liveTest = request.driver as? LiveTestDriver { liveTest.context.expectSlotToMount() }
        return .accepted(payload: request.payload, kind: .inline)
    }

    var occupants: [SurfaceOccupant] {
        sdk.inlineController.slotOccupants.map { occupant in
            sdk.occupant(
                .inline(slot: occupant.slot), occupant.payload,
                priority: sdk.campaignStore.find(occupant.payload.campaignKey)?.rulePriority)
        }
    }

    func supersede(_ occupant: SurfaceOccupant) {
        guard case .inline(let slot) = occupant.kind else { return }
        sdk.inlineController.dismissCampaign(slot, reason: .superseded)
    }

    func dismiss(_ payload: CEPTriggerPayload) {
        // Id-keyed below, so only when this delivery really is in a slot: a
        // non-inline timeout must not clear an inline slot, or its impression
        // mark, that shares the CEP id (CleverTap repeats ids) (R3-07).
        if sdk.inlineController.slotOccupants.contains(where: { surfaceOwns($0.payload, payload: payload) }) {
            sdk.inlineController.removeCampaign(payload.cepCampaignId)
            // Forget the impression mark so a re-trigger impresses to Digia afresh.
            sdk.events.resetImpression(payload.cepCampaignId)
        }
    }
}
