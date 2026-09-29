import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class IdentityManager: @unchecked Sendable {

    private static let keyDeviceId = "device_id"
    private static let keyUserId = "user_id"

    private let storage: LocalStorage
    private let lock = NSLock()

    /// Canonical persistent installation identifier.
    /// Eagerly resolved once during init. Immutable, non-nil, zero locks on read.
    let deviceId: String

    private var cachedUserId: String?
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

    func setUserId(_ userId: String) {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let listeners: [() -> Void] = lock.withLock {
            if cachedUserId == trimmed { return [] }
            cachedUserId = trimmed
            storage.set(trimmed, forKey: Self.keyUserId)
            return userChangedListeners
        }
        listeners.forEach { $0() }
    }

    func clearUserId() {
        let listeners: [() -> Void] = lock.withLock {
            guard cachedUserId != nil else { return [] }
            cachedUserId = nil
            storage.remove(forKey: Self.keyUserId)
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
