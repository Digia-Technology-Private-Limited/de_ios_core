import Foundation
import UIKit

@MainActor
final class SDKInstance: ObservableObject, DigiaCEPDelegate {
    static let shared = SDKInstance()

    @Published private(set) var config: DigiaConfig?
    @Published private(set) var sdkState: SDKState = .notInitialized
    @Published private(set) var isHostMounted = false
    @Published private(set) var isNavigationMounted = false
    @Published private(set) var appState: [String: JSONValue] = [:]

    private var activePlugin: DigiaCEPPlugin?
    private(set) var fontFactory: DUIFontFactory = DefaultFontFactory()
    private let campaignStore = CampaignStore()
    private var messageSubscribers: [String: [UUID: @Sendable (JSONValue?) -> Void]] = [:]
    private var appStateStore: AppStateStore?
    private var localStateStores: [String: StateContext] = [:]

    let appConfigStore = AppConfigStore()
    let controller = DigiaOverlayController()
    let inlineController = InlineCampaignController()
    let navigationController = DigiaNavigationController()
    let surveyOrchestrator = SurveyOrchestrator()

    private(set) var appStateStreams: [String: AppStateValueStream] = [:]
    private(set) var lastOpenedURL: URL?
    private(set) var clipboardString: String?
    private(set) var lastShareRequest: (message: String, subject: String?)?
    private(set) var lastDialogDismissed = false
    private(set) var lastBottomSheetDismissed = false

    private init() {
        controller.onEvent = { [weak self] event, payload in
            self?.activePlugin?.notifyEvent(event, payload: payload)
        }

        inlineController.onEvent = { [weak self] event, payload in
            self?.activePlugin?.notifyEvent(event, payload: payload)
        }
    }

    func initialize(_ config: DigiaConfig) async throws {
        guard self.config == nil else { return }
        self.config = config

        let resolver = DigiaConfigResolver(config: config)
        let appConfig: DigiaAppConfig?
        if let cached = try? resolver.getConfig() {
            appConfig = cached
        } else {
            appConfig = try? await resolver.getConfigAsync()
        }
        if let appConfig {
            appConfigStore.update(appConfig)
            navigationController.setInitialRoute(appConfig.initialRoute)
            try initializeAppState(from: appConfig, namespace: config.apiKey)
        }

        if let campaigns = try? await CampaignFetcher(config: config).fetch() {
            campaignStore.populate(campaigns)
        }

        sdkState = .ready
    }

    func register(_ plugin: DigiaCEPPlugin) {
        activePlugin?.teardown()
        activePlugin = plugin
        plugin.setup(delegate: self)
    }

    func triggerCampaign(_ campaignId: String) {
        guard sdkState == .ready else {
            print("[Digia] triggerCampaign(\(campaignId)) — sdkState=\(sdkState), not ready")
            return
        }
        guard
            let campaign = campaignStore.findById(campaignId) ?? campaignStore.findByKey(campaignId)
        else {
            print("[Digia] triggerCampaign(\(campaignId)) — campaign not found in store")
            return
        }
        print(
            "[Digia] triggerCampaign(\(campaignId)) — found campaign type=\(campaign.campaignType) key=\(campaign.campaignKey) surveyConfig=\(campaign.surveyConfig?.keys.sorted() ?? [])"
        )
        guard let payload = makePayload(for: campaign) else {
            print(
                "[Digia] triggerCampaign(\(campaignId)) — makePayload returned nil (type must be 'survey' AND surveyConfig non-nil)"
            )
            return
        }
        onCampaignTriggered(payload)
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

    func onNavigationMounted() {
        isNavigationMounted = true
    }

    func onNavigationUnmounted() {
        isNavigationMounted = false
    }

    func onCampaignTriggered(_ payload: InAppPayload) {
        if let campaignKey = campaignKey(from: payload) {
            guard let campaign = campaignStore.findByKey(campaignKey),
                let routedPayload = makePayload(for: campaign)
            else {
                print(
                    "[Digia] onCampaignTriggered(\(payload.id)) — campaign not found for key=\(campaignKey)"
                )
                return
            }
            routeResolvedCampaign(routedPayload)
            return
        }

        routeResolvedCampaign(payload)
    }

    private func routeResolvedCampaign(_ payload: InAppPayload) {
        let displayType = payload.content.type.lowercased()
        let placementKey = payload.content.placementKey
        let command = (payload.content.command ?? "").trimmingCharacters(in: .whitespaces)
            .uppercased()

        // Survey campaigns carry the dashboard-authored schema in
        // `args["survey_config"]`. Detected either via command == "SHOW_SURVEY"
        // or type == "survey".
        if command == "SHOW_SURVEY" || displayType == "survey" {
            startSurvey(payload: payload)
            return
        }

        if displayType == "inline", let placementKey {
            inlineController.setCampaign(placementKey, payload: payload)
        } else {
            controller.show(payload)
        }
    }

    private func makePayload(for campaign: CampaignModel) -> InAppPayload? {
        campaign.makePayload()
    }

    func onCampaignInvalidated(_ campaignID: String) {
        if controller.activePayload?.id == campaignID {
            controller.dismiss()
        }
        if surveyOrchestrator.state?.payload.id == campaignID {
            surveyOrchestrator.dismiss()
        }
        inlineController.removeCampaign(campaignID)
    }

    // MARK: - Survey lifecycle
    //
    // CEP plugin sees: Impressed (started), Dismissed (closed without finishing).
    // Internal analytics (TBD) sees: Answered, Completed.

    private func startSurvey(payload: InAppPayload) {
        guard let surveyJson = payload.content.args["survey_config"] else {
            print(
                "[Digia] startSurvey — args has no 'survey_config' key. args keys=\(payload.content.args.keys.sorted())"
            )
            return
        }
        guard case .object(let dict) = surveyJson else {
            print("[Digia] startSurvey — 'survey_config' is not an object")
            return
        }
        print("[Digia] startSurvey — survey_config keys=\(dict.keys.sorted())")
        guard let config = SurveyConfigModel.from(dict, fallbackId: payload.id) else {
            print(
                "[Digia] startSurvey — SurveyConfigModel.from(...) returned nil (likely missing/empty 'blocks' or 'nodes' arrays)"
            )
            return
        }
        let started = surveyOrchestrator.start(payload: payload, config: config)
        print(
            "[Digia] startSurvey — orchestrator.start returned \(started) (false if config has empty nodes/blocks OR another survey is already showing). nodes=\(config.nodes.count) blocks=\(config.blocks.count)"
        )
    }

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
        guard let state = surveyOrchestrator.state else { return }
        // Internal completion event would record `response` here.
        _ = response
        if !answers.isEmpty,
            let config = self.config,
            let campaignId = state.payload.cepContext["campaignId"]
        {
            SurveySubmissionReporter(config: config).report(
                campaignId: campaignId,
                survey: state.config,
                answers: answers,
                startedAt: state.startedAt
            )
        }
        activePlugin?.notifyEvent(.dismissed, payload: state.payload)
        surveyOrchestrator.dismiss()
    }

    func markSurveyDismissed() {
        guard let state = surveyOrchestrator.state else { return }
        activePlugin?.notifyEvent(.dismissed, payload: state.payload)
        surveyOrchestrator.dismiss()
    }

    /// Sets the stored config directly, simulating a completed initialization, without any
    /// network calls or async work. Intended for tests that need to pre-seed state synchronously
    /// before verifying guard-level idempotency (avoids suspension-point race conditions).
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
        isNavigationMounted = false
        fontFactory = DefaultFontFactory()
        campaignStore.clear()
        appConfigStore.clear()
        controller.dismiss()
        controller.dismissBottomSheet()
        controller.dismissDialog()
        controller.dismissToast()
        controller.clearSlots()
        inlineController.clear()
        surveyOrchestrator.dismiss()
        navigationController.reset()
        messageSubscribers.removeAll()
        appStateStore = nil
        appState.removeAll()
        appStateStreams.removeAll()
        localStateStores.removeAll()
        lastOpenedURL = nil
        clipboardString = nil
        lastShareRequest = nil
        lastDialogDismissed = false
        lastBottomSheetDismissed = false
    }

    @discardableResult
    func addMessageListener(name: String, listener: @escaping @Sendable (JSONValue?) -> Void)
        -> UUID
    {
        let token = UUID()
        var listeners = messageSubscribers[name, default: [:]]
        listeners[token] = listener
        messageSubscribers[name] = listeners
        return token
    }

    func removeMessageListener(name: String, token: UUID) {
        guard var listeners = messageSubscribers[name] else { return }
        listeners.removeValue(forKey: token)
        messageSubscribers[name] = listeners
    }

    func publishMessage(name: String, payload: JSONValue?) {
        messageSubscribers[name]?.values.forEach { listener in
            listener(payload)
        }
    }

    func setAppState(key: String, value: JSONValue) throws {
        guard let appStateStore else {
            throw AppStateStoreError.missingKey(key)
        }
        try appStateStore.update(key: key, value: value)
        appState = appStateStore.snapshot()
        appStateStreams[key]?.publish(value.anyValue)
        if let streamName = appStateStore.streamName(for: key) {
            appStateStreams[streamName]?.publish(value.anyValue)
        }
    }

    func registerStateContext(_ store: StateContext) {
        guard let namespace = store.namespace, !namespace.isEmpty else { return }
        localStateStores[namespace] = store
    }

    func unregisterStateContext(_ store: StateContext) {
        guard let namespace = store.namespace, localStateStores[namespace] === store else { return }
        localStateStores.removeValue(forKey: namespace)
    }

    func localStateStore(named namespace: String) -> StateContext? {
        localStateStores[namespace]
    }

    func openURL(_ url: URL) {
        lastOpenedURL = url
        UIApplication.shared.open(url)
    }

    func copyToClipboard(_ text: String) {
        clipboardString = text
        UIPasteboard.general.string = text
    }

    func share(message: String, subject: String?) {
        lastShareRequest = (message, subject)
    }

    func didDismissDialog() {
        lastDialogDismissed = true
    }

    func didDismissBottomSheet() {
        lastBottomSheetDismissed = true
    }

    private func initializeAppState(from appConfig: DigiaAppConfig, namespace: String) throws {
        appState.removeAll()
        appStateStreams.removeAll()
        let definitions = appConfig.appState ?? []
        let store = try AppStateStore(definitions: definitions, namespace: namespace)
        appStateStore = store
        appState = store.snapshot()
        for definition in definitions {
            let stream = AppStateValueStream(currentValue: appState[definition.name]?.anyValue)
            appStateStreams[definition.streamName] = stream
        }
    }

    private func stringArg(_ payload: InAppPayload, _ key: String) -> String? {
        guard case .string(let value)? = payload.content.args[key] else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class InlineCampaignController: ObservableObject {
    @Published private var campaigns: [String: InAppPayload] = [:]
    var onEvent: ((DigiaExperienceEvent, InAppPayload) -> Void)?

    func getCampaign(_ placementKey: String) -> InAppPayload? {
        campaigns[placementKey]
    }

    func setCampaign(_ placementKey: String, payload: InAppPayload) {
        var next = campaigns
        next[placementKey] = payload
        campaigns = next
    }

    func removeCampaign(_ campaignID: String) {
        campaigns = campaigns.filter { placementKey, payload in
            placementKey != campaignID && payload.id != campaignID
        }
    }

    func dismissCampaign(_ placementKey: String) {
        campaigns.removeValue(forKey: placementKey)
    }

    func clear() {
        campaigns.removeAll()
    }
}
