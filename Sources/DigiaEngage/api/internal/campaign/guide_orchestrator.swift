import Foundation
import Combine

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

// Ported from Android `GuideOrchestrator.kt`. Drives a multi-step guide
// (tooltip / spotlight) over the existing anchor + overlay primitives.

struct ActiveGuideState: Equatable {
    /// Monotonic identity for one guide presentation. Step transitions retain
    /// it so asynchronous image work cannot dismiss a newer presentation.
    let token: Int64
    let campaign: CampaignModel
    let stepIndex: Int
    /// The original trigger payload, retained so lifecycle events reuse the CEP's
    /// identity/metadata instead of a synthesized one (matches nudge/survey).
    let payload: CEPTriggerPayload

    var steps: [GuideStepModel] { campaign.guideConfig?.steps ?? [] }

    /// Resolved variable context: dashboard schemas merged with CEP trigger
    /// variables (CEP wins, empty CEP falls through to fallbackValue). Used by
    /// `GuideOverlayView` to interpolate `{{ placeholder }}` copy and arithmetic.
    var variableContext: VariableContext {
        let schemas = campaign.guideConfig?.variableSchemas ?? []
        return buildVariableContext(schemas: schemas, cepVars: payload.variables)
    }
    var currentStep: GuideStepModel? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }
    var hasNext: Bool { stepIndex < steps.count - 1 }
    var hasPrevious: Bool { stepIndex > 0 }
}

@MainActor
final class GuideOrchestrator: ObservableObject {
    @Published private(set) var state: ActiveGuideState? {
        didSet { onStateChanged?(state) }
    }
    var onStateChanged: ((ActiveGuideState?) -> Void)?
    private var tokenCounter: Int64 = 0

    /// Reporting context, set by `SDKInstance` at startup. Nil in standalone
    /// use (tests driving the state machine never report).
    var surfaceContext: SurfaceContext?

    /// Whether the active showing already reported its completion — a
    /// completion the CTA already fired wins over any later dismiss (R3-02,
    /// R4-D2).
    var guideCompletionFired = false
    private var lastReportedGuideStep: (token: Int64, index: Int)?
    /// Terminal reason the initiator knows and the dismiss call does not carry
    /// directly — consumed once by the next guide dismiss. Mirrors Flutter's
    /// `_pendingDismissReason`.
    var pendingGuideDismissReason: DismissReason?
    /// Screen the current guide step showed on — an anchor that unmounts after
    /// a host screen change is a screen exit, in place it is a lost target.
    var screenAtGuideStep: String?

    @discardableResult
    func start(_ campaign: CampaignModel, payload: CEPTriggerPayload) -> Bool {
        guard campaign.campaignType == "guide",
              let guideConfig = campaign.guideConfig,
              !guideConfig.steps.isEmpty,
              state == nil
        else { return false }
        reportMissingVariables(guideConfig.variableSchemas, payload: payload)
        tokenCounter &+= 1
        state = ActiveGuideState(token: tokenCounter, campaign: campaign, stepIndex: 0, payload: payload)
        return true
    }

    func advance() {
        guard let current = state else { return }
        state = current.hasNext
            ? ActiveGuideState(token: current.token, campaign: current.campaign, stepIndex: current.stepIndex + 1, payload: current.payload)
            : nil
    }

    func previous() {
        guard let current = state, current.hasPrevious else { return }
        state = ActiveGuideState(
            token: current.token,
            campaign: current.campaign,
            stepIndex: current.stepIndex - 1,
            payload: current.payload
        )
    }

    func move(to stepIndex: Int) {
        guard let current = state, current.steps.indices.contains(stepIndex) else { return }
        state = ActiveGuideState(
            token: current.token,
            campaign: current.campaign,
            stepIndex: stepIndex,
            payload: current.payload
        )
    }

    func dismiss() {
        state = nil
    }

    func dismissIfActive(payloadId: String) {
        if state?.payload.cepCampaignId == payloadId {
            state = nil
        }
    }
}

// MARK: - Guide lifecycle reporting
//
// Moved verbatim from `SDKInstance`; only the receiver changed. Guide
// reporting lives on the existing `GuideOrchestrator` rather than a new
// reporter — the one accepted deviation from Flutter's PR #253, whose
// `GuideOrchestrator`/`GuideShowcaseManager` split has no iOS equivalent.

extension GuideOrchestrator {
    private var ctx: SurfaceContext {
        guard let surfaceContext else {
            preconditionFailure("GuideOrchestrator.reporting used before surfaceContext was set")
        }
        return surfaceContext
    }

    /// Displayed-guide reason in Flutter's `_finish` order: a completion, then
    /// the initiator's pending reason, then the direct reason.
    private func resolveGuideDismissReason(explicit reason: DismissReason, completed: Bool) -> DismissReason {
        if completed { return .completed }
        return pendingGuideDismissReason ?? reason
    }

    /// `completed` overrides the lifecycle event's completion, which otherwise
    /// follows whether the guide reported a completion.
    func dismissGuide(reason: DismissReason = .userClose, completed: Bool? = nil) {
        guard let state else { return }
        let payload = state.payload
        let total = state.steps.count
        let elapsed = ctx.dwell.consumeDwellMs(payload.cepCampaignId)
        let completed = completed ?? guideCompletionFired
        let reason = resolveGuideDismissReason(explicit: reason, completed: completed)
        pendingGuideDismissReason = nil
        if !completed, total > 1 {
            ctx.events.toDigia(
                GuideEvent.StepDismissed(itemIndex: state.stepIndex + 1),
                payload: payload
            )
        }
        dismiss()
        ctx.events.toBoth(
            .dismissed(
                reason: completed ? .completed : reason,
                completed: completed
            ),
            GuideEvent.Dismissed(
                dismissReason: (completed ? .completed : reason).wire,
                abandonedAtItem: completed ? nil : state.stepIndex + 1,
                itemTotal: total,
                dwellMs: elapsed
            ),
            payload: payload
        )
        guideCompletionFired = false
    }

    func reportGuideShown() {
        guard let state else { return }
        // Snapshot for a later anchor loss, as Flutter's `_screenAtStep`.
        screenAtGuideStep = ctx.currentScreen
        let stepWasReported = lastReportedGuideStep.map {
            $0.token == state.token && $0.index == state.stepIndex
        } ?? false
        if state.currentStep?.target.anchorKey != nil {
            ctx.sdk.logNativeGuideStage(
                "render",
                "result=shown campaign_key=\(state.payload.campaignKey) step_index=\(state.stepIndex + 1)"
            )
        }
        let payload = state.payload
        let total = state.steps.count
        // The anchor produced a layout — that is exactly what the anchor
        // watchdog was waiting for.
        ctx.sdk.coordinator.anchorResolved(payload)
        if isLiveTestCepId(payload.cepCampaignId) {
            ctx.sdk.liveTestContexts[payload.cepCampaignId]?.reportShown()
        }
        if state.stepIndex == 0, ctx.dwell.elapsedMs(payload.cepCampaignId) == nil {
            ctx.dwell.markViewed(payload.cepCampaignId)
            if !isLiveTestCepId(payload.cepCampaignId) {
                ctx.services?.frequencyManager.recordShow(
                    payload.campaignKey,
                    ctx.sdk.findCampaign(payload)?.frequency
                )
            }
            ctx.events.toBoth(
                .impressed,
                GuideEvent.Viewed(
                    displayStyle: state.currentStep?.displayStyle ?? "spotlight",
                    itemTotal: total,
                    screenName: ctx.currentScreen
                ),
                payload: payload
            )
        }
        // Every step, a single one included, as on Flutter and Android; `stepWasReported` keeps it once.
        if !stepWasReported {
            lastReportedGuideStep = (state.token, state.stepIndex)
            ctx.events.toDigia(
                GuideEvent.StepViewed(
                    itemIndex: state.stepIndex + 1,
                    itemTotal: total,
                    anchorKey: state.currentStep?.target.anchorKey,
                    displayStyle: state.currentStep?.displayStyle
                ),
                payload: payload
            )
        }
    }

    func reportGuideRenderFailure(
        _ failure: AnchorlessFailure?,
        guideToken: Int64? = nil,
        stepIndex: Int? = nil
    ) {
        guard let state,
              (guideToken == nil || guideToken == state.token),
              (stepIndex == nil || stepIndex == state.stepIndex)
        else { return }
        if state.currentStep?.target.anchorKey != nil {
            ctx.sdk.logNativeGuideStage(
                "render",
                "result=failed campaign_key=\(state.payload.campaignKey) reason=\(failure?.rawValue ?? "image_load")"
            )
        }
        if ctx.sdk.isDebugBuild, state.currentStep?.target.anchorKey == nil {
            log.e(
                "Anchorless step render failed — \(failure?.rawValue ?? "image load failed") "
                    + "(step=\(state.stepIndex + 1))"
            )
        }
        let payload = state.payload
        if ctx.dwell.elapsedMs(payload.cepCampaignId) == nil {
            dismiss()
            // It never displayed, so this is a drop — and unlike a dismissal it
            // still knows *why*. Going through the lifecycle channel would
            // flatten every render failure to `cancelled`.
            ctx.sdk.coordinator.drop(
                payload,
                reason: Self.dropReason(for: failure),
                detail: failure?.rawValue ?? "Anchorless Spotlight image could not be loaded",
                extras: Self.healthExtras(for: failure),
                deliveryDetail: Self.renderFailureDetail(failure, state)
            )
            guideCompletionFired = false
        } else {
            dismissGuide(reason: .autoTimeout)
        }
        // Same mapping the organic drop two lines up just used — keeping a
        // second, live-test-only mapping beside it is exactly the two
        // spellings of one reason the shared vocabulary exists to prevent.
        ctx.sdk.liveTestContexts[payload.cepCampaignId]?.reportFailed(
            Self.dropReason(for: failure),
            message: failure?.rawValue ?? "Anchorless Spotlight image could not be loaded"
        )
    }

    func reportGuideStepClicked(
        actionType: String?,
        actionUrl: String?,
        ctaLabel: String?,
        action: EngageAction? = nil,
        elementId: String? = nil
    ) {
        guard let state, let step = state.currentStep else { return }
        ctx.events.toDigia(
            GuideEvent.StepClicked(
                itemIndex: state.stepIndex + 1,
                elementId: elementId ?? step.target.anchorKey,
                ctaLabel: ctaLabel,
                actionType: actionType,
                actionUrl: actionUrl
            ),
            payload: state.payload
        )
        if !state.hasNext,
           action != .previous {
            reportGuideCompletedIfNeeded(state)
        }
    }

    /// `anchorLeft`: the last step's anchor left while it showed. Flutter then
    /// sends the dwell as `timeToCompleteMs` and records no frequency completion.
    func reportGuideCompletedIfNeeded(_ state: ActiveGuideState, anchorLeft: Bool = false) {
        guard !guideCompletionFired else { return }
        guideCompletionFired = true
        if !anchorLeft, !isLiveTestCepId(state.payload.cepCampaignId) {
            ctx.services?.frequencyManager.recordCompleted(
                state.payload.campaignKey,
                ctx.sdk.findCampaign(state.payload)?.frequency
            )
        }
        ctx.events.toDigia(
            GuideEvent.Completed(
                itemTotal: state.steps.count,
                // Dwell since step 1 showed, as Flutter; a peek, so a later dismiss keeps it (A61).
                timeToCompleteMs: ctx.dwell.elapsedMs(state.payload.cepCampaignId)
            ),
            payload: state.payload
        )
    }

    /// The unified anchorless-failure table: one reason drives the live-test
    /// ACK, the campaign timeline and the CEP outcome on every stack. `nil` is
    /// an image-load failure; its watchdog makes `timeout` the honest reason.
    private static func dropReason(for failure: AnchorlessFailure?) -> DropReason {
        switch failure {
        case .pageKeyMismatch: return .screenNotTargeted
        case .invalidTarget, .invalidGeometry: return .anchorNotRegistered
        case .unsupportedLayout: return .invalidConfig
        case nil: return .timeout
        }
    }

    /// Delivery detail for a guide render failure (ai_docs/campaign-delivery-events.md).
    private static func renderFailureDetail(
        _ failure: AnchorlessFailure?, _ state: ActiveGuideState
    ) -> [String: Any] {
        let target = state.currentStep?.target
        var detail: [String: Any] = ["step_index": state.stepIndex]
        switch failure {
        case .pageKeyMismatch:
            if let pageKey = target?.anchorlessTarget?.pageKey { detail["page_key"] = pageKey }
        case .invalidTarget, .invalidGeometry:
            if let anchorKey = target?.anchorKey { detail["anchor_key"] = anchorKey }
        case .unsupportedLayout:
            return ["cause": "anchorless_layout"]
        case nil:
            detail["cause"] = "image_load"
        }
        return detail
    }

    /// Health extras for an anchorless drop: `invalid_config` needs its cause.
    private static func healthExtras(for failure: AnchorlessFailure?) -> [String: String]? {
        failure == .unsupportedLayout ? ["cause": "anchorless_layout"] : nil
    }
}
