import Foundation
import Testing

@testable import DigiaEngage

@MainActor
@Suite("SDKServices unit tests", .serialized)
struct SDKServicesTests {

    @Test("default services are initialized with expected core instances")
    func defaultServicesInitialization() {
        let services = SDKServices()

        #expect(services.analyticsService == nil)
        #expect(services.frequencyManager == nil)
        #expect(services.campaignStore.isEmpty)
        #expect(!services.deviceIdProvider.deviceId.isEmpty)
        #expect(services.deviceIdProvider.getDeviceId() == services.deviceIdProvider.deviceId)
        #expect(!services.identityManager.deviceId.isEmpty)
        #expect(services.identityManager.getDeviceId() == services.deviceIdProvider.deviceId)
        #expect(!services.sessionManager.sessionId.isEmpty)
        #expect(services.networkClient is URLSessionNetworkClient)
    }

    @Test("storage operations read, write, and remove values")
    func storageOperations() {
        let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "test_storage_\(UUID().uuidString)")!)

        #expect(storage.string(forKey: "key_str") == nil)
        storage.set("hello", forKey: "key_str")
        #expect(storage.string(forKey: "key_str") == "hello")

        storage.set(true, forKey: "key_bool")
        #expect(storage.bool(forKey: "key_bool") == true)

        storage.set(42, forKey: "key_int")
        #expect(storage.integer(forKey: "key_int") == 42)

        storage.set(3.14, forKey: "key_double")
        #expect(storage.double(forKey: "key_double") == 3.14)

        let data = "data_val".data(using: .utf8)
        storage.set(data, forKey: "key_data")
        #expect(storage.data(forKey: "key_data") == data)

        storage.removeObject(forKey: "key_str")
        #expect(storage.string(forKey: "key_str") == nil)

        storage.remove(forKey: "key_bool")
        #expect(storage.bool(forKey: "key_bool") == false)
    }

    @Test("deviceIdProvider caches and persists device id")
    func deviceIdProviderBehavior() {
        let suiteName = "test_device_id_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let storage = UserDefaultsLocalStorage(defaults: defaults)

        let fixedId = "custom-uuid-12345"
        let provider = DefaultDeviceIdProvider(
            storage: storage,
            storageKey: "test_dev_id",
            idGenerator: { fixedId }
        )

        #expect(provider.deviceId == fixedId)
        #expect(provider.getDeviceId() == fixedId)
        #expect(storage.string(forKey: "test_dev_id") == fixedId)

        // Subsequent provider using same storage reads persisted ID
        let secondProvider = DefaultDeviceIdProvider(
            storage: storage,
            storageKey: "test_dev_id",
            idGenerator: { "different-id" }
        )
        #expect(secondProvider.deviceId == fixedId)
    }

    @Test("custom dependency injection into SDKServices")
    func customDependencyInjection() {
        let customStorage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "custom_suite_\(UUID().uuidString)")!)
        let customDeviceIdProvider = DefaultDeviceIdProvider(storage: customStorage, storageKey: "custom_key", idGenerator: { "injected-id" })
        let customCampaignStore = CampaignStore()
        let customLiveTestService = LiveTestService()
        let customNetworkClient = MockNetworkClient()

        let services = SDKServices(
            storage: customStorage,
            deviceIdProvider: customDeviceIdProvider,
            campaignStore: customCampaignStore,
            liveTestService: customLiveTestService,
            networkClient: customNetworkClient
        )

        #expect(services.deviceIdProvider.deviceId == "injected-id")
        #expect(services.campaignStore === customCampaignStore)
        #expect(services.liveTestService === customLiveTestService)
        #expect(services.networkClient === customNetworkClient)
    }

    @Test("networkClient default and mock injection")
    func networkClientInjection() async throws {
        let mock = MockNetworkClient()
        mock.enqueueResponse(statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
        let services = SDKServices(networkClient: mock)
        let request = NetworkRequest(url: URL(string: "https://example.com")!)
        let response = try await services.networkClient.execute(request: request)
        #expect(response.statusCode == 200)
        #expect(response.isSuccessful)
        #expect(mock.recordedRequests.count == 1)
        #expect(mock.recordedRequests[0].url.absoluteString == "https://example.com")
    }

    @Test("resetForTesting clears services state")
    func resetForTestingClearsState() throws {
        let services = SDKServices()
        let campaign = try #require(CampaignModel.fromJson([
            "id": "c1",
            "campaignKey": "key1",
            "campaignType": "inline",
            "templateConfig": [
                "templateType": "carousel",
                "slotKey": "slot1",
                "items": [["imageUrl": "https://example.com/1.png"]],
            ],
        ]))
        services.campaignStore.populate([campaign])
        #expect(!services.campaignStore.isEmpty)

        services.resetForTesting()

        #expect(services.campaignStore.isEmpty)
        #expect(services.analyticsService == nil)
        #expect(services.frequencyManager == nil)
    }

    @Test("SDKInstance forwarders point to underlying services")
    func sdkInstanceForwarders() throws {
        let instance = SDKInstance.shared
        instance.resetForTesting()

        #expect(instance.services != nil)
        #expect(instance.campaignStore === instance.services.campaignStore)
        #expect(instance.componentRegistry === instance.services.componentRegistry)
        #expect(instance.liveTestService === instance.services.liveTestService)
        #expect(instance.submissionReporter === instance.services.submissionReporter)
        #expect(instance.storage === instance.services.storage)
        #expect(instance.deviceIdProvider.deviceId == instance.services.deviceIdProvider.deviceId)
        #expect(instance.identityManager.deviceId == instance.services.identityManager.deviceId)
        #expect(instance.networkClient === instance.services.networkClient)

        let campaign = try #require(CampaignModel.fromJson([
            "id": "c2",
            "campaignKey": "key2",
            "campaignType": "inline",
            "templateConfig": [
                "templateType": "carousel",
                "slotKey": "slot2",
                "items": [["imageUrl": "https://example.com/2.png"]],
            ],
        ]))
        instance.campaignStore.populate([campaign])
        #expect(instance.services.campaignStore.find("key2")?.id == "c2")

        instance.resetForTesting()
        #expect(instance.services.campaignStore.isEmpty)
    }
}
