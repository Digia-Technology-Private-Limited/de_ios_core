import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class IdentityManager: @unchecked Sendable {

    private static let keyDeviceId = "device_id"
    private static let keyUserId = "user_id"
    private static let keyUserHash = "user_hash"

    private let storage: LocalStorage
    private let lock = NSLock()

    /// Canonical persistent installation identifier.
    /// Eagerly resolved once during init. Immutable, non-nil, zero locks on read.
    let deviceId: String

    private var cachedUserId: String?
    private var cachedUserHash: String?
    private var userChangedListeners: [() -> Void] = []

    init(
        storage: LocalStorage,
        idGenerator: @Sendable () -> String = IdentityManager.systemIdGenerator
    ) {
        self.storage = storage

        if let existing = storage.string(forKey: Self.keyDeviceId)?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            self.deviceId = existing
        } else {
            let newId = idGenerator()
            storage.set(newId, forKey: Self.keyDeviceId)
            self.deviceId = newId
        }

        if let existingUser = storage.string(forKey: Self.keyUserId)?.trimmingCharacters(in: .whitespacesAndNewlines), !existingUser.isEmpty {
            self.cachedUserId = existingUser
            self.cachedUserHash = storage.string(forKey: Self.keyUserHash)
        } else {
            self.cachedUserId = nil
        }
    }

    /// The production device ID source: the vendor identifier, read on the
    /// main thread, or a random UUID when it is unavailable.
    static func systemIdGenerator() -> String {
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

    var userId: String? {
        lock.withLock { cachedUserId }
    }

    /// The host-issued proof of `userId`, or nil when none was given.
    var userHash: String? {
        lock.withLock { cachedUserHash }
    }

    /// Ignores blank IDs. For the current user, only a new non-nil `userHash`
    /// is stored. A new user replaces the hash, or clears it.
    func setUserId(_ userId: String, userHash: String? = nil) {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let listeners: [() -> Void] = lock.withLock {
            if cachedUserId == trimmed {
                if let userHash, userHash != cachedUserHash {
                    cachedUserHash = userHash
                    storage.set(userHash, forKey: Self.keyUserHash)
                }
                return []
            }
            cachedUserId = trimmed
            cachedUserHash = userHash
            storage.set(trimmed, forKey: Self.keyUserId)
            if let userHash {
                storage.set(userHash, forKey: Self.keyUserHash)
            } else {
                storage.remove(forKey: Self.keyUserHash)
            }
            return userChangedListeners
        }
        listeners.forEach { $0() }
    }

    func clearUserId() {
        let listeners: [() -> Void] = lock.withLock {
            guard cachedUserId != nil else { return [] }
            cachedUserId = nil
            cachedUserHash = nil
            storage.remove(forKey: Self.keyUserId)
            storage.remove(forKey: Self.keyUserHash)
            return userChangedListeners
        }
        listeners.forEach { $0() }
    }

    /// Called after the stored user ID actually changes: set to a new value,
    /// or cleared from non-nil. Never for a repeat of the current value.
    func addUserChangedListener(_ listener: @escaping () -> Void) {
        lock.withLock { userChangedListeners.append(listener) }
    }
}
