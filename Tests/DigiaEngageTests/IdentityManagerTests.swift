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
        let generatedId = manager.deviceId

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
        #expect(manager.deviceId == existingId)
    }

    @Test("User ID management: setUserId persists, trims, caches, and clearUserId removes it")
    func userIdLifecycle() {
        let (storage, _) = makeIsolatedStorage()
        let scopedStorage = storage.scoped("identity")
        let manager = IdentityManager(storage: scopedStorage)

        #expect(manager.userId == nil)

        // setUserId with trimming
        manager.setUserId("  customer_42  ")
        #expect(manager.userId == "customer_42")
        #expect(scopedStorage.string(forKey: "user_id") == "customer_42")

        // blank string setUserId is ignored
        manager.setUserId("   ")
        #expect(manager.userId == "customer_42")
        #expect(scopedStorage.string(forKey: "user_id") == "customer_42")

        // clearUserId removes user_id and sets userId to nil
        manager.clearUserId()
        #expect(manager.userId == nil)
        #expect(scopedStorage.string(forKey: "user_id") == nil)

        // calling clearUserId when already nil is idempotent no-op
        manager.clearUserId()
        #expect(manager.userId == nil)
        #expect(scopedStorage.string(forKey: "user_id") == nil)
    }

    @Test("Existing user_id in storage is loaded into memory on init")
    func existingUserIdLoadedOnInit() {
        let (storage, _) = makeIsolatedStorage()
        let scopedStorage = storage.scoped("identity")
        scopedStorage.set("user_prior", forKey: "user_id")

        let manager = IdentityManager(storage: scopedStorage)
        #expect(manager.userId == "user_prior")
    }

    @Test("Identity stability on logout: clearUserId does NOT rotate or modify deviceId")
    func clearUserIdDoesNotRotateDeviceId() {
        let (storage, _) = makeIsolatedStorage()
        let scopedStorage = storage.scoped("identity")
        let manager = IdentityManager(storage: scopedStorage)

        let initialDeviceId = manager.deviceId
        manager.setUserId("logged_in_user")
        #expect(manager.deviceId == initialDeviceId)

        manager.clearUserId()
        #expect(manager.userId == nil)
        #expect(manager.deviceId == initialDeviceId)
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
                    _ = manager.userId
                }
                group.addTask {
                    manager.clearUserId()
                    _ = manager.userId
                }
            }
        }

        let finalUser = manager.userId
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
}
