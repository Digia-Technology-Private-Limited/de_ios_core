import Foundation

@MainActor
final class SDKServices {
    var storage: LocalStorage
    let identityManager: IdentityManager
    var sessionManager: SessionManager
    var sessionReporter: SessionReporter?
    var deviceIdProvider: DeviceIdProvider
    var networkClient: any NetworkClient
    var analyticsService: AnalyticsService?
    var frequencyManager: FrequencyManager?
    var campaignStore: CampaignStore
    var submissionReporter: SubmissionReporter
    var componentRegistry: ComponentRegistryService
    var liveTestService: LiveTestService

    init(
        storage: LocalStorage = UserDefaultsLocalStorage(),
        identityManager: IdentityManager? = nil,
        sessionManager: SessionManager? = nil,
        sessionReporter: SessionReporter? = nil,
        deviceIdProvider: DeviceIdProvider? = nil,
        analyticsService: AnalyticsService? = nil,
        frequencyManager: FrequencyManager? = nil,
        campaignStore: CampaignStore = CampaignStore(),
        submissionReporter: SubmissionReporter? = nil,
        componentRegistry: ComponentRegistryService? = nil,
        liveTestService: LiveTestService? = nil,
        networkClient: (any NetworkClient)? = nil
    ) {
        self.storage = storage
        let resolvedIdentityManager = identityManager ?? IdentityManager(storage: storage.scoped("identity"))
        self.identityManager = resolvedIdentityManager
        let resolvedSessionManager = sessionManager ?? SessionManager(storage: storage)
        self.sessionManager = resolvedSessionManager
        self.sessionReporter = sessionReporter
        let resolvedDeviceIdProvider = deviceIdProvider ?? DefaultDeviceIdProvider(identityManager: resolvedIdentityManager)
        self.deviceIdProvider = resolvedDeviceIdProvider
        let resolvedNetworkClient = networkClient ?? URLSessionNetworkClient(
            sessionIdProvider: { [weak resolvedSessionManager] in resolvedSessionManager?.sessionId }
        )
        self.networkClient = resolvedNetworkClient
        self.analyticsService = analyticsService
        self.frequencyManager = frequencyManager
        self.campaignStore = campaignStore
        self.submissionReporter = submissionReporter ?? SubmissionReporter(
            identityManager: resolvedIdentityManager,
            deviceIdProvider: resolvedDeviceIdProvider,
            sessionIdProvider: { [weak resolvedSessionManager] in resolvedSessionManager?.sessionId },
            storage: storage.scoped("identity"),
            networkClient: resolvedNetworkClient
        )
        self.componentRegistry = componentRegistry ?? ComponentRegistryService(
            storage: storage.scoped("registry"),
            networkClient: resolvedNetworkClient
        )
        self.liveTestService = liveTestService ?? LiveTestService(
            storage: storage.scoped("live_test"),
            ackReporter: LiveTestAckReporter(networkClient: resolvedNetworkClient),
            networkClient: resolvedNetworkClient
        )
    }

    func resetForTesting() {
        analyticsService?.clear()
        analyticsService = nil
        sessionReporter = nil
        frequencyManager = nil
        campaignStore.clear()
        liveTestService.stop()
    }
}
