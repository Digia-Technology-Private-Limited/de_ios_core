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
    /// Survey whose start-engagement ("welcome_start") click has already fired
    /// (once per showing).
    private var welcomeStartToken: Int64?
    /// Per-question viewed-at timestamps, keyed by "<surveyToken>:<nodeId>".
    /// Used to compute `time_to_answer_ms` on QuestionAnswered.
    private var questionViewedAt: [String: Date] = [:]
    private var analyticsService: AnalyticsService?
    /// Native frequency capping for all managed campaigns (nudge, survey, and —
    /// on React Native — guides, whose lifecycle events arrive over the bridge).
    private var frequencyManager: FrequencyManager?

    /// Set by the RN bridge. When non-nil the SDK is RN-driven: guides render in
    /// JS, so on a guide trigger native only applies frequency capping and (if
    /// allowed) invokes this hook to ask JS to render, instead of rendering the
    /// guide natively. Nil in pure-native apps, where guides render natively.
    var onGuideRenderRequest: ((CEPTriggerPayload) -> Void)?

    // Event system (mirrors Android): a fan-out emitter over two sinks — the
    // coarse CEP channel (`toCep`) and Digia's rich analytics (`toDigia`).
    // Campaign id/type are resolved from the store inside the Digia sink.
    private let dwellTracker = DwellTracker()
    private var events: EngageEventEmitter!

    private init() {
        events = EngageEventEmitter(
            cep: CepPluginSink { [weak self] event, payload in
                self?.activePlugin?.notifyEvent(event, payload: payload)
            },
            digia: DigiaAnalyticsSink(
                getAnalyticsService: { [weak self] in self?.analyticsService },
                getCampaign: { [weak self] key in self?.campaignStore.find(key) }
            )
        )
        // Forward overlay CTA actions to the active CEP plugin (native open is the
        // renderer's fallback when no plugin handles it). Mirrors Android's wiring.
        controller.onAction = { [weak self] actionType, url, payload in
            self?.activePlugin?.notifyAction(actionType: actionType, url: url, payload: payload) ?? false
        }
    }

    func initialize(_ config: DigiaConfig) async throws {
        guard self.config == nil else { return }
        self.config = config
        DigiaEndpoints.configure(config)

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
        analyticsService = AnalyticsService.create(config: config)

        // Frequency capping pulls the authoritative sessionId from analytics so
        // `session` windows track the same session the backend sees.
        frequencyManager = FrequencyManager(
            sessionIdProvider: { [weak self] in self?.analyticsService?.identity.sessionId }
        )

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

    func onCampaignTriggered(_ payload: CEPTriggerPayload) {
        logVerbose(
            "onCampaignTriggered cepCampaignId='\(payload.cepCampaignId)' "
                + "campaignKey='\(payload.campaignKey)'")
        // Route purely by the campaignKey resolved from the store (mirrors
        // Android) — fall back to cepCampaignId when no campaignKey was supplied.
        let key = payload.campaignKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey =
            key.isEmpty
            ? payload.cepCampaignId.trimmingCharacters(in: .whitespacesAndNewlines)
            : key
        guard !resolvedKey.isEmpty, campaignStore.find(resolvedKey) != nil else {
            logVerbose("campaign dropped — no campaign for key '\(resolvedKey)'")
            return
        }
        routeByCampaignKey(resolvedKey, payload: payload)
    }

    private func routeByCampaignKey(_ key: String, payload: CEPTriggerPayload) {
        guard let campaign = campaignStore.find(key) else {
            logVerbose("routeByCampaignKey: no campaign found for key '\(key)'")
            return
        }

        logVerbose("routeByCampaignKey key='\(key)' type='\(campaign.campaignType)'")
        switch campaign.config {
        case .inline(let cfg):
            logVerbose(
                "routeByCampaignKey INLINE slotKey='\(cfg.slotKey)' items=\(cfg.items.count)")
            inlineController.setCarouselConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: payload)
            // syncTemplate semantics: CEP considers an inline slot shown and done
            // the moment it is delivered. Digia's impression fires only when the
            // slot first renders (see reportSlotFirstRender).
            events.toCep(.impressed, payload: payload)
            events.toCep(.dismissed, payload: payload)
        case .story(let cfg):
            inlineController.setStoryConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: payload)
            events.toCep(.impressed, payload: payload)
            events.toCep(.dismissed, payload: payload)
        case .guide:
            if let renderViaJs = onGuideRenderRequest {
                // RN: native owns capping, JS owns rendering. Gate here; the
                // counter is bumped later on the guide's "Digia Experience
                // Viewed" event (see captureAnalyticsEvent).
                if let capReason = frequencyManager?.blockReason(campaignKey: key, policy: campaign.frequency) {
                    logVerbose("guide dropped — frequency capped: key=\(key) cep=\(payload.cepCampaignId) reason=\(capReason) policy=\(String(describing: campaign.frequency))")
                    return
                }
                renderViaJs(payload)
                return
            }
            dwellTracker.markViewed(payload.cepCampaignId)
            guideOrchestrator.start(campaign, payload: payload)
        case .nudge(let nudgeConfig):
            if let capReason = frequencyManager?.blockReason(campaignKey: key, policy: campaign.frequency) {
                logVerbose("nudge dropped — frequency capped: key=\(key) cep=\(payload.cepCampaignId) reason=\(capReason) policy=\(String(describing: campaign.frequency))")
                return
            }
            // Resolve variable context: dashboard schemas define type + fallback;
            // CEP trigger variables win over fallbacks (D3′).
            let variableContext = buildVariableContext(
                schemas: nudgeConfig.variableSchemas,
                cepVars: payload.variables
            )
            controller.showNudge(
                DigiaNudgePresentation(
                    config: nudgeConfig,
                    payload: payload,
                    variables: variableContext.values.isEmpty && variableContext.types.isEmpty ? nil : variableContext
                ))
        case .survey(let cfg):
            if let capReason = frequencyManager?.blockReason(campaignKey: key, policy: campaign.frequency) {
                logVerbose("survey dropped — frequency capped: key=\(key) cep=\(payload.cepCampaignId) reason=\(capReason) policy=\(String(describing: campaign.frequency))")
                return
            }
            if !surveyOrchestrator.start(payload: payload, config: cfg) {
                logVerbose("survey campaign dropped: another survey is on screen: \(key)")
            }
        }
    }

    func onCampaignInvalidated(_ campaignID: String) {
        if controller.activeNudge?.payload.cepCampaignId == campaignID {
            controller.dismissNudge()
        }
        if surveyOrchestrator.state?.payload.cepCampaignId == campaignID {
            surveyOrchestrator.dismiss()
        }
        inlineController.removeCampaign(campaignID)
        guideOrchestrator.dismissIfActive(campaignKey: campaignID)
        // Forget the impression mark so a re-trigger impresses to Digia afresh.
        events.resetImpression(campaignID)
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
        let config = state.config
        dwellTracker.markViewed(state.payload.cepCampaignId)
        // Bump frequency on "Digia Experience Viewed" (the moment the survey shows).
        let campaignKey = state.payload.campaignKey
        frequencyManager?.recordShow(campaignKey, campaignStore.find(campaignKey)?.frequency)
        events.toBoth(
            .impressed,
            SurveyEvent.Viewed(
                itemTotal: config.questionCount,
                hasWelcome: config.hasWelcome,
                hasThanks: config.hasThanks,
                hasBranching: config.hasBranching
            ),
            payload: state.payload
        )
    }

    /// The survey's start engagement — fired once per showing. When a welcome
    /// screen is present this is its "Start" CTA tap; when there's no welcome
    /// screen it is raised on the first continue (see `reportSurveyAnswered` /
    /// `reportSurveyQuestionSkipped`).
    func reportSurveyWelcomeStart() {
        guard let state = surveyOrchestrator.state else { return }
        if welcomeStartToken == state.token { return }
        welcomeStartToken = state.token
        events.toDigia(SurveyEvent.Clicked(elementId: "welcome_start"), payload: state.payload)
    }

    /// When no welcome screen exists, the first continue is the start engagement.
    private func ensureWelcomeStartIfNoWelcome(_ state: ActiveSurveyState) {
        if !state.config.hasWelcome { reportSurveyWelcomeStart() }
    }

    /// A survey question became visible. `itemIndex` is its 1-based shown position.
    func reportSurveyQuestionViewed(nodeId: String, itemIndex: Int) {
        guard let state = surveyOrchestrator.state else { return }
        guard let block = state.config.blockForNode(nodeId) else { return }
        if block.type.isContent { return }
        questionViewedAt[Self.questionKey(token: state.token, nodeId: nodeId)] = Date()
        let typeWire = block.type.rawValue
        events.toDigia(
            SurveyEvent.QuestionViewed(
                questionId: nodeId,
                questionTitle: Self.questionTitle(block),
                questionType: typeWire,
                itemIndex: itemIndex,
                itemTotal: state.config.questionCount,
                blockType: typeWire,
                blockId: block.id,
                isRequired: block.required
            ),
            payload: state.payload
        )
    }

    /// An eligible optional question was skipped (advanced without an answer).
    func reportSurveyQuestionSkipped(nodeId: String, itemIndex: Int) {
        guard let state = surveyOrchestrator.state else { return }
        ensureWelcomeStartIfNoWelcome(state)
        guard let block = state.config.blockForNode(nodeId) else { return }
        questionViewedAt.removeValue(forKey: Self.questionKey(token: state.token, nodeId: nodeId))
        events.toDigia(
            SurveyEvent.QuestionSkipped(
                questionId: nodeId,
                questionTitle: Self.questionTitle(block),
                itemIndex: itemIndex,
                blockType: block.type.rawValue,
                blockId: block.id),
            payload: state.payload
        )
    }

    /// Fired each time the user answers a question (one event per answered question).
    func reportSurveyAnswered(stepId: String, answer: [String: JSONValue]) {
        guard let state = surveyOrchestrator.state else { return }
        ensureWelcomeStartIfNoWelcome(state)
        let block = state.config.blockForNode(stepId)
        let values = Self.stringArray(answer["values"])
        let comment = Self.stringValue(answer["comment"])
        let viewedKey = Self.questionKey(token: state.token, nodeId: stepId)
        let timeToAnswerMs: Int64? = questionViewedAt[viewedKey].map {
            Int64(Date().timeIntervalSince($0) * 1000)
        }
        questionViewedAt.removeValue(forKey: viewedKey)
        let scaleBounds = block.flatMap(Self.scaleBounds)
        events.toDigia(
            SurveyEvent.QuestionAnswered(
                questionId: stepId,
                questionTitle: block.flatMap(Self.questionTitle),
                questionType: block?.type.rawValue,
                answerValue: values.first,
                answerText: comment ?? (values.isEmpty ? nil : values.joined(separator: ", ")),
                blockType: block?.type.rawValue,
                blockId: block?.id,
                answerLabel: block.flatMap { Self.answerLabel(block: $0, values: values) },
                answerOptions: values.count > 1 ? values : nil,
                scaleMin: scaleBounds?.min,
                scaleMax: scaleBounds?.max,
                timeToAnswerMs: timeToAnswerMs,
                answer: Self.foundation(answer)
            ),
            payload: state.payload
        )
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

        // Permanent stop on "Digia Experience Completed" when stopOn is set.
        let campaignKey = state.payload.campaignKey
        frequencyManager?.recordCompleted(campaignKey, campaignStore.find(campaignKey)?.frequency)

        // Analytics "Completed" fires once per survey showing, regardless of
        // whether a submission is reported to the backend below.
        let answeredCount = answers.isEmpty ? response.count : answers.count
        events.toDigia(
            SurveyEvent.Completed(
                itemTotal: state.config.questionCount,
                answeredCount: answeredCount,
                timeToCompleteMs: Int64(Date().timeIntervalSince(state.startedAt) * 1000),
                response: Self.foundation(response)
            ),
            payload: state.payload
        )

        if answers.isEmpty {
            logVerbose("reportSurveyCompleted: skip submission — answers is empty")
            return
        }
        guard let config = self.config else {
            logVerbose(
                "reportSurveyCompleted: skip submission — SDK not initialized (config is nil)")
            return
        }
        guard let campaignId = campaignStore.find(state.payload.campaignKey)?.id else {
            logVerbose(
                "reportSurveyCompleted: skip submission — no campaign for key '\(state.payload.campaignKey)'")
            return
        }
        logVerbose(
            "reportSurveyCompleted: submitting campaignId=\(campaignId) answers=\(answers.count)")
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

    func markSurveyDismissed(abandonedAtItem: Int? = nil, answeredCount: Int? = nil) {
        guard let state = surveyOrchestrator.state else { return }
        events.toBoth(
            .dismissed,
            SurveyEvent.Dismissed(
                abandonedAtItem: abandonedAtItem,
                itemTotal: state.config.questionCount,
                answeredCount: answeredCount,
                dwellMs: dwellTracker.consumeDwellMs(state.payload.cepCampaignId)
            ),
            payload: state.payload
        )
        clearQuestionViewedAt(token: state.token)
        surveyOrchestrator.dismiss()
    }

    private func clearQuestionViewedAt(token: Int64) {
        let prefix = "\(token):"
        questionViewedAt = questionViewedAt.filter { !$0.key.hasPrefix(prefix) }
    }

    func markInitializedForTesting(with config: DigiaConfig) {
        self.config = config
    }

    func setCampaignsForTesting(_ campaigns: [CampaignModel]) {
        campaignStore.populate(campaigns)
        sdkState = .ready
    }

    func setUserId(_ userId: String) {
        analyticsService?.setUserId(userId)
    }

    func clearUserId() {
        analyticsService?.clearUserId()
    }

    // MARK: - Nudge lifecycle
    //
    // Impression and Dismissed go to both CEP and Digia analytics (toBoth); a
    // primary-button Click is a Digia-only engagement signal (toDigia), matching
    // Android's NudgeNodeRenderer.

    func reportNudgeImpression() {
        guard let nudge = controller.activeNudge else { return }
        dwellTracker.markViewed(nudge.payload.cepCampaignId)
        // Bump frequency on "Digia Experience Viewed" (the moment the nudge shows).
        let campaignKey = nudge.payload.campaignKey
        frequencyManager?.recordShow(campaignKey, campaignStore.find(campaignKey)?.frequency)
        events.toBoth(
            .impressed,
            NudgeEvent.Viewed(displayStyle: nudge.config.surface.displayType.displayStyle),
            payload: nudge.payload
        )
    }

    func emitNudgeClick(
        elementId: String? = nil,
        ctaLabel: String? = nil,
        actionType: String? = nil,
        actionUrl: String? = nil,
        ctaRole: String? = nil
    ) {
        guard let payload = controller.activeNudge?.payload else { return }
        events.toDigia(
            NudgeEvent.Clicked(
                elementId: elementId,
                ctaLabel: ctaLabel,
                actionType: actionType,
                actionUrl: actionUrl,
                ctaRole: ctaRole,
                // ms since the nudge was viewed (peek — the nudge is still open).
                timeToActionMs: dwellTracker.elapsedMs(payload.cepCampaignId)
            ),
            payload: payload
        )
    }

    func markNudgeDismissed() {
        guard let nudge = controller.activeNudge else { return }
        events.toBoth(
            .dismissed,
            NudgeEvent.Dismissed(dwellMs: dwellTracker.consumeDwellMs(nudge.payload.cepCampaignId)),
            payload: nudge.payload
        )
        controller.dismissNudge()
    }

    // MARK: - Inline slot lifecycle
    //
    // CEP is Impressed + Dismissed instantly at route time (syncTemplate
    // semantics — see routeByCampaignKey). Digia's impression fires once, when
    // the slot first actually renders, deduped per campaign.

    func reportSlotFirstRender(_ payload: CEPTriggerPayload) {
        guard let campaign = campaignStore.find(payload.campaignKey) else { return }
        let viewed: EngageAnalyticsEvent
        switch campaign.config {
        case .inline(let cfg):
            viewed = CarouselEvent.Viewed(itemTotal: cfg.items.count, slotKey: cfg.slotKey)
        case .story(let cfg):
            viewed = StoriesEvent.Viewed(slotKey: cfg.slotKey)
        default:
            return
        }
        events.digiaImpressionOnce(payload: payload, event: viewed)
    }

    /// A carousel item scrolled into view. `auto` = autoplay advance vs manual swipe.
    func reportCarouselStepViewed(
        payload: CEPTriggerPayload, itemIndex: Int, itemTotal: Int, auto: Bool
    ) {
        events.toDigia(
            CarouselEvent.StepViewed(itemIndex: itemIndex, itemTotal: itemTotal, auto: auto),
            payload: payload
        )
    }

    /// A carousel item (or its CTA) was tapped.
    func reportCarouselStepClicked(payload: CEPTriggerPayload, itemIndex: Int, actionUrl: String?) {
        let actionType = actionUrl.map { _ in "deeplink" }
        // The first item tap also counts as an experience-level engagement click (once).
        events.digiaExperienceClickedOnce(
            payload: payload,
            event: CarouselEvent.Clicked(actionType: actionType, actionUrl: actionUrl)
        )
        events.toDigia(
            CarouselEvent.StepClicked(
                itemIndex: itemIndex, actionType: actionType, actionUrl: actionUrl),
            payload: payload
        )
    }

    // MARK: - Inline story lifecycle (full-screen player)

    /// A story was opened (ring/thumbnail tapped) — drives open rate.
    func reportStoryOpened(_ payload: CEPTriggerPayload) {
        events.toDigia(StoriesEvent.Opened(), payload: payload)
    }

    /// A story frame became visible. `itemIndex` is 1-based; `itemTotal` = frames.
    func reportStoryStepViewed(_ payload: CEPTriggerPayload, itemIndex: Int, itemTotal: Int) {
        events.toDigia(StoriesEvent.StepViewed(itemIndex: itemIndex, itemTotal: itemTotal), payload: payload)
    }

    /// A CTA inside a story frame was tapped.
    func reportStoryStepClicked(
        _ payload: CEPTriggerPayload,
        itemIndex: Int,
        ctaLabel: String?,
        actionType: String?,
        actionUrl: String?
    ) {
        events.toDigia(
            StoriesEvent.StepClicked(
                itemIndex: itemIndex,
                ctaLabel: ctaLabel,
                actionType: actionType,
                actionUrl: actionUrl
            ),
            payload: payload
        )
    }

    /// Story closed before the last frame. `itemIndex` is the 1-based frame on close.
    func reportStoryStepDismissed(_ payload: CEPTriggerPayload, itemIndex: Int) {
        events.toDigia(StoriesEvent.StepDismissed(itemIndex: itemIndex), payload: payload)
    }

    /// Last story frame viewed. `itemTotal` = frames; `timeToCompleteMs` from open.
    func reportStoryCompleted(_ payload: CEPTriggerPayload, itemTotal: Int, timeToCompleteMs: Int64?) {
        events.toDigia(
            StoriesEvent.Completed(itemTotal: itemTotal, timeToCompleteMs: timeToCompleteMs),
            payload: payload
        )
    }

    // MARK: - Guide lifecycle

    func dismissGuide() {
        guard let state = guideOrchestrator.state else { return }
        let payload = state.payload
        guideOrchestrator.dismiss()
        events.toBoth(
            .dismissed,
            GuideEvent.Dismissed(
                abandonedAtItem: state.stepIndex + 1,
                itemTotal: state.campaign.guideConfig?.steps.count,
                dwellMs: dwellTracker.consumeDwellMs(payload.cepCampaignId)
            ),
            payload: payload
        )
    }

    /// Public analytics entry point for JS-rendered RN campaigns (guides). The JS
    /// layer fires each lifecycle event by its Engage matrix `eventName` with
    /// wire-keyed `props`; this maps it to the typed analytics event and records
    /// it to Digia. CEP forwarding for JS-rendered campaigns is handled JS-side.
    func captureAnalyticsEvent(campaignKey: String, eventName: String, props: [String: Any]) {
        guard let event = guideEventFor(eventName: eventName, props: props) else {
            logVerbose(
                "captureAnalyticsEvent: unsupported event '\(eventName)' for key '\(campaignKey)' — skipped"
            )
            return
        }
        let campaign = campaignStore.find(campaignKey)
        // Native frequency capping for RN-rendered guides: bump on Viewed, apply
        // the permanent stop on Completed (when the policy opts into stopOn).
        switch eventName {
        case "Digia Experience Viewed":
            frequencyManager?.recordShow(campaignKey, campaign?.frequency)
        case "Digia Experience Completed":
            frequencyManager?.recordCompleted(campaignKey, campaign?.frequency)
        default:
            break
        }
        let payload = CEPTriggerPayload(
            cepCampaignId: campaign?.id ?? campaignKey, campaignKey: campaignKey)
        events.toDigia(event, payload: payload)
    }

    private func guideEventFor(eventName: String, props: [String: Any]) -> EngageAnalyticsEvent? {
        func str(_ key: String) -> String? { props[key] as? String }
        func int(_ key: String) -> Int? {
            (props[key] as? NSNumber)?.intValue ?? (props[key] as? Int)
        }
        switch eventName {
        case "Digia Experience Viewed":
            return GuideEvent.Viewed(
                displayStyle: str("display_style") ?? "", itemTotal: int("step_total") ?? 0)
        case "Digia Step Viewed":
            return GuideEvent.StepViewed(
                itemIndex: int("step_index") ?? 0,
                itemTotal: int("step_total") ?? 0,
                anchorKey: str("anchor_key"),
                displayStyle: str("display_style")
            )
        // Guides only have Step Clicked in the matrix; map both click variants to it.
        case "Digia Step Clicked", "Digia Experience Clicked":
            return GuideEvent.StepClicked(
                itemIndex: int("step_index") ?? 0,
                elementId: str("element_id"),
                ctaLabel: str("cta_label"),
                actionType: str("action_type"),
                actionUrl: str("action_url")
            )
        case "Digia Step Dismissed":
            return GuideEvent.StepDismissed(itemIndex: int("step_index") ?? 0)
        case "Digia Experience Dismissed":
            return GuideEvent.Dismissed(
                abandonedAtItem: int("abandoned_at_step") ?? int("step_index"),
                itemTotal: int("step_total"))
        case "Digia Experience Completed":
            return GuideEvent.Completed(itemTotal: int("step_total"))
        default:
            return nil
        }
    }

    /// Converts a `JSONValue` map to a Foundation map for JSON serialization,
    /// dropping `null` entries.
    private static func foundation(_ map: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in map {
            if let any = value.anyValue { result[key] = any }
        }
        return result
    }

    private static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let arr)? = value else { return [] }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    /// The block's title text, or nil when empty (blank titles are not worth
    /// shipping over the wire).
    private static func questionTitle(_ block: SurveyBlock) -> String? {
        let title = block.title.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Comma-joined labels for the selected option ids on a choice block.
    /// Returns nil when the block has no options or no selection matches —
    /// (e.g. rating/nps/text inputs whose answer values aren't option ids).
    private static func answerLabel(block: SurveyBlock, values: [String]) -> String? {
        guard !values.isEmpty, !block.options.isEmpty else { return nil }
        let labels = values.compactMap { id in
            block.options.first { $0.id == id }?.label
        }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ", ")
    }

    /// Numeric scale bounds for scored blocks (Rating 1–5, NPS 0–10). Other
    /// block types have no scale.
    private static func scaleBounds(_ block: SurveyBlock) -> (min: Int, max: Int)? {
        switch block.type {
        case .rating: return (1, 5)
        case .nps, .npsEmoji, .npsSmiley: return (0, 10)
        default: return nil
        }
    }

    /// Stable per-question key for `questionViewedAt`. Scoped by survey token
    /// so a re-show of the same survey doesn't reuse a stale viewed-at.
    private static func questionKey(token: Int64, nodeId: String) -> String {
        "\(token):\(nodeId)"
    }

    func resetForTesting() {
        activePlugin?.teardown()
        activePlugin = nil
        analyticsService?.clear()
        analyticsService = nil
        frequencyManager = nil
        config = nil
        sdkState = .notInitialized
        isHostMounted = false
        fontFactory = DefaultFontFactory()
        campaignStore.clear()
        controller.dismissNudge()
        controller.dismissStoryOverlay()
        inlineController.clear()
        surveyOrchestrator.dismiss()
        guideOrchestrator.dismiss()
        events.clearImpressions()
        dwellTracker.clear()
        completedSurveyToken = nil
        welcomeStartToken = nil
        questionViewedAt.removeAll()
    }

}

// MARK: - Survey config metrics (Engage matrix props)

extension SurveyConfigModel {
    /// Configured questions = graph nodes whose block is an actual prompt (not
    /// content chrome like welcome / text-media / result pages).
    fileprivate var questionCount: Int {
        nodes.filter { node in
            guard let block = blockFor(node) else { return false }
            return !block.type.isContent
        }.count
    }

    fileprivate var hasWelcome: Bool { welcomeBlock() != nil }

    fileprivate var hasThanks: Bool { blocks.contains { $0.type == .resultPage } }

    fileprivate var hasBranching: Bool { nodes.contains { $0.branching.type != .linear } }

    fileprivate func blockForNode(_ nodeId: String) -> SurveyBlock? {
        nodeById(nodeId).flatMap { blockFor($0) }
    }
}
