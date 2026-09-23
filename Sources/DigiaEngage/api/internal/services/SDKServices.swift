import Foundation

@MainActor
final class SDKServices {
    var storage: LocalStorage
    var deviceIdProvider: DeviceIdProvider
    var analyticsService: AnalyticsService?
    var frequencyManager: FrequencyManager?
    var campaignStore: CampaignStore
    var submissionReporter: SubmissionReporter
    var componentRegistry: ComponentRegistryService
    var liveTestService: LiveTestService

    init(
        storage: LocalStorage = UserDefaultsLocalStorage(),
        deviceIdProvider: DeviceIdProvider? = nil,
        analyticsService: AnalyticsService? = nil,
        frequencyManager: FrequencyManager? = nil,
        campaignStore: CampaignStore = CampaignStore(),
        submissionReporter: SubmissionReporter? = nil,
        componentRegistry: ComponentRegistryService? = nil,
        liveTestService: LiveTestService? = nil
    ) {
        self.storage = storage
        let resolvedDeviceIdProvider = deviceIdProvider ?? DefaultDeviceIdProvider(storage: storage.scoped("identity"))
        self.deviceIdProvider = resolvedDeviceIdProvider
        self.analyticsService = analyticsService
        self.frequencyManager = frequencyManager
        self.campaignStore = campaignStore
        self.submissionReporter = submissionReporter ?? SubmissionReporter(
            deviceIdProvider: resolvedDeviceIdProvider,
            storage: storage.scoped("identity")
        )
        self.componentRegistry = componentRegistry ?? ComponentRegistryService(storage: storage.scoped("registry"))
        self.liveTestService = liveTestService ?? LiveTestService(storage: storage.scoped("live_test"))
    }

    func resetForTesting() {
        analyticsService?.clear()
        analyticsService = nil
        frequencyManager = nil
        campaignStore.clear()
        liveTestService.stop()
    }
}
