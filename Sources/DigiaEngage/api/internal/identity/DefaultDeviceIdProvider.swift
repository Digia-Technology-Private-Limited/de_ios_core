import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class DefaultDeviceIdProvider: DeviceIdProvider, @unchecked Sendable {
    private let identityManager: IdentityManager?
    private let storage: LocalStorage?
    private let storageKey: String
    private let idGenerator: (@Sendable () -> String)?
    private let lock = NSLock()
    private var cachedDeviceId: String?

    init(identityManager: IdentityManager) {
        self.identityManager = identityManager
        self.storage = nil
        self.storageKey = "device_id"
        self.idGenerator = nil
    }

    init(
        storage: LocalStorage = UserDefaultsLocalStorage().scoped("identity"),
        storageKey: String = "device_id",
        idGenerator: @escaping @Sendable () -> String = {
            #if canImport(UIKit)
            let idfv: String?
            if Thread.isMainThread {
                idfv = MainActor.assumeIsolated { UIDevice.current.identifierForVendor?.uuidString }
            } else {
                idfv = DispatchQueue.main.sync { UIDevice.current.identifierForVendor?.uuidString }
            }
            return idfv ?? UUID().uuidString
            #else
            return UUID().uuidString
            #endif
        }
    ) {
        self.identityManager = nil
        self.storage = storage
        self.storageKey = storageKey
        self.idGenerator = idGenerator
    }

    var deviceId: String {
        if let identityManager {
            return identityManager.getDeviceId()
        }

        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedDeviceId {
            return cached
        }
        guard let storage, let idGenerator else { return "" }
        if let existing = storage.string(forKey: storageKey), !existing.isEmpty {
            cachedDeviceId = existing
            return existing
        }
        if storageKey != "digia_engage_device_id",
           let legacy = storage.string(forKey: "digia_engage_device_id"),
           !legacy.isEmpty {
            storage.set(legacy, forKey: storageKey)
            cachedDeviceId = legacy
            return legacy
        }

        let newId = idGenerator()
        storage.set(newId, forKey: storageKey)
        cachedDeviceId = newId
        return newId
    }
}
