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
    private var messageSubscribers: [String: [UUID: @Sendable (JSONValue?) -> Void]] = [:]
    private var appStateStore: AppStateStore?
    private var localStateStores: [String: StateContext] = [:]

    let appConfigStore = AppConfigStore()
    let campaignStore = CampaignStore()
    let controller = DigiaOverlayController()
    let inlineController = InlineCampaignController()
    let guideOrchestrator = GuideOrchestrator()
    let navigationController = DigiaNavigationController()

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

        if let family = config.fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines),
           !family.isEmpty {
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

    func onNavigationMounted() {
        isNavigationMounted = true
    }

    func onNavigationUnmounted() {
        isNavigationMounted = false
    }

    func onCampaignTriggered(_ payload: InAppPayload) {
        // campaign_key path (native CEP plugins, e.g. CleverTap): resolve the full
        // campaign from the store and route by campaignType, mirroring Android.
        if let campaignKey = payload.content.campaignKey, !campaignKey.isEmpty {
            routeByCampaignKey(campaignKey, payload: payload)
            return
        }

        // Typed path (RN/JS-driven): content already carries display info.
        let displayType = payload.content.type.lowercased()
        let placementKey = payload.content.placementKey

        if displayType == "inline", let placementKey {
            inlineController.setCampaign(placementKey, payload: payload)
        } else {
            controller.show(payload)
        }
    }

    private func routeByCampaignKey(_ key: String, payload: InAppPayload) {
        guard let campaign = campaignStore.find(key) else {
            logVerbose("campaign_key path: no campaign found for key '\(key)'")
            return
        }

        switch campaign.config {
        case let .inline(cfg):
            let routed = InAppPayload(
                id: payload.id,
                content: InAppPayloadContent(type: "inline", placementKey: cfg.slotKey, campaignKey: key),
                cepContext: payload.cepContext
            )
            inlineController.setCarouselConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: routed)
        case .story:
            logVerbose("campaign_key path: story campaigns not supported natively yet (key '\(key)')")
        case .guide:
            guideOrchestrator.start(campaign)
        case .nudge:
            controller.show(payload)
        }
    }

    func onCampaignInvalidated(_ campaignID: String) {
        if controller.activePayload?.id == campaignID {
            controller.dismiss()
        }
        inlineController.removeCampaign(campaignID)
        guideOrchestrator.dismissIfActive(campaignKey: campaignID)
    }

    /// Sets the stored config directly, simulating a completed initialization, without any
    /// network calls or async work. Intended for tests that need to pre-seed state synchronously
    /// before verifying guard-level idempotency (avoids suspension-point race conditions).
    func markInitializedForTesting(with config: DigiaConfig) {
        self.config = config
    }

    func resetForTesting() {
        activePlugin?.teardown()
        activePlugin = nil
        config = nil
        sdkState = .notInitialized
        isHostMounted = false
        isNavigationMounted = false
        fontFactory = DefaultFontFactory()
        appConfigStore.clear()
        campaignStore.clear()
        controller.dismiss()
        controller.dismissBottomSheet()
        controller.dismissDialog()
        controller.dismissToast()
        controller.clearSlots()
        inlineController.clear()
        guideOrchestrator.dismiss()
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
    func addMessageListener(name: String, listener: @escaping @Sendable (JSONValue?) -> Void) -> UUID {
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

}

@MainActor
final class InlineCampaignController: ObservableObject {
    @Published private var campaigns: [String: InAppPayload] = [:]
    @Published private var carouselConfigs: [String: InlineCarouselConfig] = [:]
    var onEvent: ((DigiaExperienceEvent, InAppPayload) -> Void)?

    func getCampaign(_ placementKey: String) -> InAppPayload? {
        campaigns[placementKey]
    }

    func getCarouselConfig(_ placementKey: String) -> InlineCarouselConfig? {
        carouselConfigs[placementKey]
    }

    func setCampaign(_ placementKey: String, payload: InAppPayload) {
        var next = campaigns
        next[placementKey] = payload
        campaigns = next
    }

    func setCarouselConfig(_ placementKey: String, config: InlineCarouselConfig) {
        var next = carouselConfigs
        next[placementKey] = config
        carouselConfigs = next
    }

    func removeCampaign(_ campaignID: String) {
        let removedKeys = campaigns
            .filter { $0.key == campaignID || $0.value.id == campaignID }
            .map(\.key)
        campaigns = campaigns.filter { placementKey, payload in
            placementKey != campaignID && payload.id != campaignID
        }
        for key in removedKeys {
            carouselConfigs.removeValue(forKey: key)
        }
    }

    func dismissCampaign(_ placementKey: String) {
        campaigns.removeValue(forKey: placementKey)
        carouselConfigs.removeValue(forKey: placementKey)
    }

    func clear() {
        campaigns.removeAll()
        carouselConfigs.removeAll()
    }
}
