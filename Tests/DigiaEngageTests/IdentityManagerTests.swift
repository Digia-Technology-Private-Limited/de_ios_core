import Foundation
import Testing

@testable import DigiaEngage

@Suite("IdentityManager unit tests", .serialized)
struct IdentityManagerTests {

    private func makeIsolatedStorage() -> (LocalStorage, UserDefaults) {
        let suiteName = "test_identity_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let storage = UserDefaultsLocalStorage(defaults: defaults)
        return (storage, defaults)
    }

    @Test("Fresh install generates valid UUID deviceId and persists it under device_id key")
    func freshInstallGeneratesDeviceId() {
        let (storage, _) = makeIsolatedStorage()
        let scopedStorage = storage.scoped("identity")

        #expect(scopedStorage.string(forKey: "device_id") == nil)

        let manager = IdentityManager(storage: scopedStorage)
        let generatedId = manager.getDeviceId()

        #expect(!generatedId.isEmpty)
        #expect(manager.deviceId == generatedId)
        #expect(scopedStorage.string(forKey: "device_id") == generatedId)
        #expect(UUID(uuidString: generatedId) != nil)
    }

    @Test("Existing deviceId in storage is read eagerly without re-generating")
    func existingDeviceIdIsReused() {
        let (storage, _) = makeIsolatedStorage()
        let scopedStorage = storage.scoped("identity")
        let existingId = "persisted-device-id-999"
        scopedStorage.set(existingId, forKey: "device_id")

        let manager = IdentityManager(storage: scopedStorage, idGenerator: { "never-called" })

        #expect(manager.deviceId == existingId)
        #expect(manager.getDeviceId() == existingId)
    }

    @Test("Eager immutability: getDeviceId returns the exact same string across 1,000 parallel calls")
    func parallelDeviceIdAccessIsImmutable() async {
        let (storage, _) = makeIsolatedStorage()
        let manager = IdentityManager(storage: storage.scoped("identity"))
        let expectedId = manager.deviceId

        await withTaskGroup(of: String.self) { group in
            for _ in 0..<1_000 {
                group.addTask {
                    manager.getDeviceId()
                }
            }
            for await id in group {
                #expect(id == expectedId)
            }
        }
    }

    @Test("User ID management: setUserId persists, trims, caches, and clearUserId removes it")
    func userIdLifecycle() {
        let (storage, _) = makeIsolatedStorage()
        let scopedStorage = storage.scoped("identity")
        let manager = IdentityManager(storage: scopedStorage)

        #expect(manager.getUserId() == nil)

        // setUserId with trimming
        manager.setUserId("  customer_42  ")
        #expect(manager.getUserId() == "customer_42")
        #expect(scopedStorage.string(forKey: "user_id") == "customer_42")

        // blank string setUserId is ignored
        manager.setUserId("   ")
        #expect(manager.getUserId() == "customer_42")
        #expect(scopedStorage.string(forKey: "user_id") == "customer_42")

        // clearUserId removes user_id and sets getUserId to nil
        manager.clearUserId()
        #expect(manager.getUserId() == nil)
        #expect(scopedStorage.string(forKey: "user_id") == nil)

        // calling clearUserId when already nil is idempotent no-op
        manager.clearUserId()
        #expect(manager.getUserId() == nil)
        #expect(scopedStorage.string(forKey: "user_id") == nil)
    }

    @Test("Existing user_id in storage is loaded into memory on init")
    func existingUserIdLoadedOnInit() {
        let (storage, _) = makeIsolatedStorage()
        let scopedStorage = storage.scoped("identity")
        scopedStorage.set("user_prior", forKey: "user_id")

        let manager = IdentityManager(storage: scopedStorage)
        #expect(manager.getUserId() == "user_prior")
    }

    @Test("Identity stability on logout: clearUserId does NOT rotate or modify deviceId")
    func clearUserIdDoesNotRotateDeviceId() {
        let (storage, _) = makeIsolatedStorage()
        let scopedStorage = storage.scoped("identity")
        let manager = IdentityManager(storage: scopedStorage)

        let initialDeviceId = manager.getDeviceId()
        manager.setUserId("logged_in_user")
        #expect(manager.getDeviceId() == initialDeviceId)

        manager.clearUserId()
        #expect(manager.getUserId() == nil)
        #expect(manager.getDeviceId() == initialDeviceId)
        #expect(scopedStorage.string(forKey: "device_id") == initialDeviceId)
    }

    @Test("Thread safety: concurrent setUserId and clearUserId operations")
    func concurrentUserIdModifications() async {
        let (storage, _) = makeIsolatedStorage()
        let manager = IdentityManager(storage: storage.scoped("identity"))

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<500 {
                let userId = "user_\(i)"
                group.addTask {
                    manager.setUserId(userId)
                    _ = manager.getUserId()
                }
                group.addTask {
                    manager.clearUserId()
                    _ = manager.getUserId()
                }
            }
        }

        let finalUser = manager.getUserId()
        if let finalUser {
            #expect(!finalUser.isEmpty)
        }
    }

    @Test("Domain isolation: only device_id and user_id keys are written, NEVER anonymous_id")
    func domainIsolationNoAnonymousIdKey() {
        let (storage, defaults) = makeIsolatedStorage()
        let scopedStorage = storage.scoped("identity")
        let manager = IdentityManager(storage: scopedStorage)

        manager.setUserId("isolated_user")

        #expect(scopedStorage.string(forKey: "device_id") != nil)
        #expect(scopedStorage.string(forKey: "user_id") == "isolated_user")
        #expect(scopedStorage.string(forKey: "anonymous_id") == nil)

        // Also check raw parent defaults to ensure no un-prefixed or stray keys were written
        #expect(defaults.string(forKey: "anonymous_id") == nil)
        #expect(defaults.string(forKey: "identity.anonymous_id") == nil)
        #expect(defaults.string(forKey: "identity.device_id") == manager.deviceId)
        #expect(defaults.string(forKey: "identity.user_id") == "isolated_user")
    }

    @MainActor
    @Test("Pre-initialization buffering: setUserId called before initialize is flushed to services")
    func preInitUserIdBuffering() async throws {
        let instance = SDKInstance.shared
        instance.resetForTesting()

        // Call setUserId before initialize()
        instance.setUserId("early_bird_user")

        // Verify IdentityManager has it persisted immediately
        #expect(instance.identityManager.getUserId() == "early_bird_user")

        // Now initialize the SDK
        let config = DigiaConfig(
            apiKey: "test_key",
            analyticsConfig: AnalyticsConfig(enabled: true)
        )
        try await instance.initialize(config)

        #expect(instance.identityManager.getUserId() == "early_bird_user")
        #expect(instance.analyticsService?.identity.userId == "early_bird_user")

        instance.resetForTesting()
    }

    @MainActor
    @Test("Pre-initialization buffering: clearUserId before initialize leaves user cleared")
    func preInitClearUserIdBuffering() async throws {
        let instance = SDKInstance.shared
        instance.resetForTesting()

        // First set, then immediately clear before initialize()
        instance.setUserId("temp_user")
        instance.clearUserId()

        #expect(instance.identityManager.getUserId() == nil)

        let config = DigiaConfig(
            apiKey: "test_key",
            analyticsConfig: AnalyticsConfig(enabled: true)
        )
        try await instance.initialize(config)

        #expect(instance.identityManager.getUserId() == nil)
        #expect(instance.analyticsService?.identity.userId == nil)

        instance.resetForTesting()
    }
}
