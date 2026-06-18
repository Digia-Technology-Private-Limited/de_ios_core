import Foundation
import Combine

@MainActor
final class SDKInstance: ObservableObject, DigiaCEPDelegate {
    static let shared = SDKInstance()

    @Published private(set) var config: DigiaConfig?
    @Published private(set) var sdkState: SDKState = .notInitialized
    @Published private(set) var isHostMounted = false

    private var activePlugin: DigiaCEPPlugin?
    private(set) var fontFactory: DUIFontFactory = DefaultFontFactory()

    let campaignStore = CampaignStore()
    let controller = DigiaOverlayController()
    let inlineController = InlineCampaignController()
    let guideOrchestrator = GuideOrchestrator()
    let surveyOrchestrator = SurveyOrchestrator()

    private var completedSurveyToken: Int64?

    private init() {
        controller.onEvent = { [weak self] event, payload in
            self?.activePlugin?.notifyEvent(event, payload: payload)
        }

        controller.onAction = { [weak self] actionType, url, payload in
            self?.activePlugin?.notifyAction(actionType: actionType, url: url, payload: payload)
        }

        inlineController.onEvent = { [weak self] event, payload in
            self?.activePlugin?.notifyEvent(event, payload: payload)
        }
    }

    func initialize(_ config: DigiaConfig) async throws {
        guard self.config == nil else { return }
        self.config = config

        if let family = config.fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines),
            !family.isEmpty
        {
            fontFactory = ConfiguredFontFactory(fontFamily: family)
        }

        do {
            let campaigns = try await CampaignFetcher(config: config).fetch()
            campaignStore.populate(campaigns)
            if campaignStore.isEmpty {
                logVerbose("No campaigns fetched — CampaignStore is empty")
            }
        } catch {
            // Campaign fetch failure must not block SDK readiness.
            logVerbose("CampaignFetcher failed: \(error)")
        }

        sdkState = .ready

        if let plugin = activePlugin, !plugin.healthCheck().isHealthy {
            plugin.setup(delegate: self)
        }
    }

    private func logVerbose(_ message: String) {
        guard config?.logLevel == .verbose else { return }
        print("Digia [SDKInstance] \(message)")
    }

    func register(_ plugin: DigiaCEPPlugin) {
        activePlugin?.teardown()
        activePlugin = plugin
        plugin.setup(delegate: self)
    }

    func registerFontFactory(_ factory: DUIFontFactory) {
        fontFactory = factory
    }

    func registerPlaceholderForSlot(propertyID: String) -> Int? {
        activePlugin?.registerPlaceholder(propertyID: propertyID)
    }

    func deregisterPlaceholderForSlot(_ id: Int) {
        activePlugin?.deregisterPlaceholder(id)
    }

    func onHostMounted() {
        isHostMounted = true
    }

    func onHostUnmounted() {
        isHostMounted = false
    }

    func onCampaignTriggered(_ payload: InAppPayload) {
        logVerbose(
            "onCampaignTriggered id='\(payload.id)' type='\(payload.content.type)' "
            + "campaignKey='\(payload.content.campaignKey ?? "nil")' "
            + "placementKey='\(payload.content.placementKey ?? "nil")'")
        // campaign_key path (native CEP plugins, e.g. CleverTap): resolve the full
        // campaign from the store and route by campaignType, mirroring Android.
        // The key may arrive either in content.campaignKey or — as the RN bridge
        // sends it — as payload.id. Mirror Android's fallback chain
        // (campaign_key ?? digiaKey ?? payload.id) and route whenever the resolved
        // key matches a known campaign, so inline/survey/nudge/guide campaigns
        // delivered without an explicit content.campaignKey still work.
        func argKey(_ key: String) -> String? {
            if case .string(let value)? = payload.content.args[key] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
        let explicitKey = payload.content.campaignKey?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let fallbackKey = payload.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey =
            (explicitKey?.isEmpty == false ? explicitKey : nil)
            ?? argKey("campaign_key") ?? argKey("campaignKey")
            ?? (fallbackKey.isEmpty ? nil : fallbackKey)

        logVerbose("onCampaignTriggered resolvedKey='\(resolvedKey ?? "nil")'")
        if let campaignKey = resolvedKey, campaignStore.find(campaignKey) != nil {
            routeByCampaignKey(campaignKey, payload: payload)
            return
        }

        // Fallback: RN-triggered campaigns may omit `campaignKey`. If the payload id
        // matches a stored campaign, route by it (covers native nudges via the RN bridge).
        if campaignStore.find(payload.id) != nil {
            routeByCampaignKey(payload.id, payload: payload)
            return
        }

        // Typed path (RN/JS-driven): content already carries display info.
        let displayType = payload.content.type.lowercased()
        let placementKey = payload.content.placementKey?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let viewId = payload.content.viewId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = payload.content.command?.uppercased() ?? ""

        let routeInline: Bool = {
            if displayType == "inline", let pk = placementKey, !pk.isEmpty { return true }
            if let pk = placementKey, !pk.isEmpty, let vid = viewId, !vid.isEmpty {
                if command.isEmpty || command == "SHOW_INLINE" { return true }
            }
            return false
        }()

        if routeInline, let pk = placementKey, !pk.isEmpty {
            inlineController.setCampaign(pk, payload: payload)
        } else {
            controller.show(payload)
        }
    }

    private func routeByCampaignKey(_ key: String, payload: InAppPayload) {
        guard let campaign = campaignStore.find(key) else {
            logVerbose("campaign_key path: no campaign found for key '\(key)'")
            return
        }

        logVerbose("routeByCampaignKey key='\(key)' type='\(campaign.campaignType)'")
        switch campaign.config {
        case .inline(let cfg):
            logVerbose("routeByCampaignKey INLINE slotKey='\(cfg.slotKey)' items=\(cfg.items.count)")
            let routed = InAppPayload(
                id: payload.id,
                content: InAppPayloadContent(
                    type: "inline", placementKey: cfg.slotKey, campaignKey: key),
                cepContext: payload.cepContext
            )
            inlineController.setCarouselConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: routed)
        case .story(let cfg):
            let routed = InAppPayload(
                id: payload.id,
                content: InAppPayloadContent(
                    type: "inline", placementKey: cfg.slotKey, campaignKey: key),
                cepContext: payload.cepContext
            )
            inlineController.setStoryConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: routed)
        case .guide:
            guideOrchestrator.start(campaign, variables: payload.content.variables)
        case .nudge(let nudgeConfig):
            let routed = InAppPayload(
                id: payload.id,
                content: InAppPayloadContent(
                    type: "nudge",
                    args: payload.content.args.merging([
                        "campaign_type": .string("nudge"),
                        "display_style": .string(nudgeConfig.surface.displayType.displayStyle),
                    ]) { _, new in new },
                    campaignKey: key
                ),
                cepContext: payload.cepContext
            )
            // Dashboard-declared defaults first, CEP trigger variables layered
            // on top (CEP wins) — mirrors Flutter's `digia_host._presentNudge`.
            var mergedVariables = nudgeConfig.defaultVariables
            for (key, value) in payload.content.variables ?? [:] {
                mergedVariables[key] = value
            }
            controller.showNudge(DigiaNudgePresentation(
                config: nudgeConfig,
                payload: routed,
                variables: mergedVariables.isEmpty ? nil : mergedVariables
            ))
        case .survey(let cfg):
            let routed = InAppPayload(
                id: campaign.campaignKey,
                content: InAppPayloadContent(
                    type: "survey",
                    command: "SHOW_SURVEY",
                    args: [
                        "campaign_key": .string(campaign.campaignKey),
                        "campaign_id": .string(campaign.id),
                    ],
                    campaignKey: campaign.campaignKey
                ),
                cepContext: {
                    var ctx = payload.cepContext
                    ctx["campaignId"] = campaign.id
                    ctx["campaignKey"] = campaign.campaignKey
                    return ctx
                }()
            )
            if !surveyOrchestrator.start(payload: routed, config: cfg) {
                logVerbose("survey campaign dropped: another survey is on screen: \(key)")
            }
        }
    }

    func onCampaignInvalidated(_ campaignID: String) {
        if controller.activePayload?.id == campaignID {
            controller.dismiss()
        }
        if controller.activeNudge?.payload.id == campaignID {
            controller.dismissNudge()
        }
        if surveyOrchestrator.state?.payload.id == campaignID {
            surveyOrchestrator.dismiss()
        }
        inlineController.removeCampaign(campaignID)
        guideOrchestrator.dismissIfActive(campaignKey: campaignID)
    }

    // MARK: - Survey lifecycle
    //
    // CEP plugin sees: Impressed (started), Dismissed (every teardown — closed
    // without finishing AND completed; all routed through markSurveyDismissed).
    // Internal analytics (TBD) sees: Answered, Completed.
    // Surveys are started from `routeByCampaignKey` once a `survey` campaign is
    // resolved from the store, so there is no separate `startSurvey` entry point.

    /// Fired once when the survey first becomes visible (treated as an impression).
    func reportSurveyStarted() {
        guard let state = surveyOrchestrator.state else { return }
        activePlugin?.notifyEvent(.impressed, payload: state.payload)
    }

    func reportSurveyAnswered(stepId: String, answer: [String: JSONValue]) {
        // Internal-only event; no CEP notification. Hook for future analytics.
        _ = stepId
        _ = answer
    }

    func markSurveyCompleted(response: [String: JSONValue], answers: [String: SurveyAnswer] = [:]) {
        reportSurveyCompleted(response: response, answers: answers)
        markSurveyDismissed()
    }

    func reportSurveyCompleted(response: [String: JSONValue], answers: [String: SurveyAnswer] = [:])
    {
        guard let state = surveyOrchestrator.state else {
            logVerbose("reportSurveyCompleted: skip — no active survey state")
            return
        }
        if completedSurveyToken == state.token {
            logVerbose("reportSurveyCompleted: skip — already reported for token=\(state.token)")
            return
        }
        completedSurveyToken = state.token
        _ = response
        if answers.isEmpty {
            logVerbose("reportSurveyCompleted: skip — answers is empty")
            return
        }
        guard let config = self.config else {
            logVerbose("reportSurveyCompleted: skip — SDK not initialized (config is nil)")
            return
        }
        guard let campaignId = state.payload.cepContext["campaignId"] else {
            logVerbose("reportSurveyCompleted: skip — campaignId missing from cepContext")
            return
        }
        logVerbose("reportSurveyCompleted: submitting campaignId=\(campaignId) answers=\(answers.count)")
        SurveySubmissionReporter(config: config).report(
            campaignId: campaignId,
            survey: state.config,
            answers: answers,
            startedAt: state.startedAt
        )
    }

    func dismissCompletedSurvey() {
        markSurveyDismissed()
    }

    func markSurveyDismissed() {
        guard let state = surveyOrchestrator.state else { return }
        activePlugin?.notifyEvent(.dismissed, payload: state.payload)
        surveyOrchestrator.dismiss()
    }

    func markInitializedForTesting(with config: DigiaConfig) {
        self.config = config
    }

    func setCampaignsForTesting(_ campaigns: [CampaignModel]) {
        campaignStore.populate(campaigns)
        sdkState = .ready
    }

    func resetForTesting() {
        activePlugin?.teardown()
        activePlugin = nil
        config = nil
        sdkState = .notInitialized
        isHostMounted = false
        fontFactory = DefaultFontFactory()
        campaignStore.clear()
        controller.dismiss()
        controller.dismissNudge()
        controller.dismissStoryOverlay()
        inlineController.clear()
        surveyOrchestrator.dismiss()
        guideOrchestrator.dismiss()
    }

}
