import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class AnalyticsIdentityManager {
    private let storage: LocalStorage
    private var _anonymousId: String = ""
    private var _userId: String?
    private var _sessionId: String = ""
    private var _lastEventDate: Date?
    private var _sessionTimeoutMs: Int = 30 * 60 * 1_000

    /// Called whenever the session ID rotates. Wired by AnalyticsService to report the new session.
    var onSessionRotated: (() -> Void)?

    private static let keyAnonymousId = "anonymous_id"
    private static let keyUserId = "user_id"

    init(storage: LocalStorage = UserDefaultsLocalStorage().scoped("identity")) {
        self.storage = storage
    }

    convenience init(defaults: UserDefaults) {
        self.init(storage: UserDefaultsLocalStorage(defaults: defaults).scoped("identity"))
    }

    var anonymousId: String { _anonymousId }
    var userId: String? { _userId }
    var sessionId: String { _sessionId }

    func resolveAnonymousId() -> String { loadOrCreate(key: Self.keyAnonymousId) }

    func initialize(sessionTimeoutMs: Int) {
        _sessionTimeoutMs = sessionTimeoutMs
        _anonymousId = resolveAnonymousId()
        _userId = storage.string(forKey: Self.keyUserId)
        _sessionId = UUID().uuidString
        _lastEventDate = Date()
    }

    func setUserId(_ userId: String) {
        guard _userId != userId else { return }
        _userId = userId
        storage.set(userId, forKey: Self.keyUserId)
        rotateSession()
    }

    func clearUserId() {
        guard _userId != nil else { return }
        _userId = nil
        storage.removeObject(forKey: Self.keyUserId)
        rotateSession()
    }

    func captureEventTime() {
        maybeExpireSession()
        _lastEventDate = Date()
    }

    func maybeExpireSession() {
        guard let last = _lastEventDate else { return }
        let elapsedMs = Int(Date().timeIntervalSince(last) * 1_000)
        if elapsedMs >= _sessionTimeoutMs {
            rotateSession()
        }
    }

    private func rotateSession() {
        _sessionId = UUID().uuidString
        _lastEventDate = Date()
        onSessionRotated?()
    }

    private func loadOrCreate(key: String) -> String {
        if let existing = storage.string(forKey: key), !existing.isEmpty {
            return existing
        }
        if key == Self.keyAnonymousId, let deviceId = storage.string(forKey: "device_id"), !deviceId.isEmpty {
            storage.set(deviceId, forKey: key)
            return deviceId
        }
        #if canImport(UIKit)
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        let id = UUID().uuidString
        #endif
        storage.set(id, forKey: key)
        return id
    }
}
