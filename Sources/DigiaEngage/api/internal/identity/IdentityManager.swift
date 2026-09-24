import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class IdentityManager: @unchecked Sendable {

    private static let keyDeviceId = "device_id"
    private static let keyUserId = "user_id"

    private let storage: LocalStorage
    private let lock = NSLock()

    /// Canonical persistent installation identifier.
    /// Eagerly resolved once during init. Immutable, non-nil, zero locks on read.
    public let deviceId: String

    private var cachedUserId: String?
    private var userChangedListeners: [() -> Void] = []

    init(
        storage: LocalStorage,
        idGenerator: (@Sendable () -> String)? = nil
    ) {
        self.storage = storage

        if let existing = storage.string(forKey: Self.keyDeviceId)?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            self.deviceId = existing
        } else {
            let newId: String
            if let idGenerator {
                newId = idGenerator()
            } else {
                #if canImport(UIKit)
                let idfv: String?
                if Thread.isMainThread {
                    idfv = MainActor.assumeIsolated { UIDevice.current.identifierForVendor?.uuidString }
                } else {
                    idfv = DispatchQueue.main.sync { UIDevice.current.identifierForVendor?.uuidString }
                }
                newId = idfv ?? UUID().uuidString
                #else
                newId = UUID().uuidString
                #endif
            }
            storage.set(newId, forKey: Self.keyDeviceId)
            self.deviceId = newId
        }

        if let existingUser = storage.string(forKey: Self.keyUserId)?.trimmingCharacters(in: .whitespacesAndNewlines), !existingUser.isEmpty {
            self.cachedUserId = existingUser
        } else {
            self.cachedUserId = nil
        }
    }

    public func getDeviceId() -> String {
        return deviceId
    }

    public func getUserId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedUserId
    }

    public var userId: String? {
        getUserId()
    }

    public func setUserId(_ userId: String) {
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

    public func clearUserId() {
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
