import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class AnalyticsIdentityManager {
    private let defaults: UserDefaults
    private var _anonymousId: String = ""
    private var _userId: String?
    private var _sessionId: String = ""
    private var _lastEventDate: Date?
    private var _sessionTimeoutMs: Int = 30 * 60 * 1_000

    /// Called whenever the session ID rotates. Wired by AnalyticsService to report the new session.
    var onSessionRotated: (() -> Void)?

    private static let keyAnonymousId = "digia_anonymous_id"
    private static let keyUserId = "digia_user_id"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var anonymousId: String { _anonymousId }
    var userId: String? { _userId }
    var sessionId: String { _sessionId }

    func initialize(sessionTimeoutMs: Int) {
        _sessionTimeoutMs = sessionTimeoutMs
        _anonymousId = loadOrCreate(key: Self.keyAnonymousId)
        _userId = defaults.string(forKey: Self.keyUserId)
        _sessionId = UUID().uuidString
    }

    func setUserId(_ userId: String) {
        _userId = userId
        defaults.set(userId, forKey: Self.keyUserId)
        rotateSession()
    }

    func clearUserId() {
        _userId = nil
        defaults.removeObject(forKey: Self.keyUserId)
        rotateSession()
    }

    func captureEventTime() {
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
        onSessionRotated?()
    }

    private func loadOrCreate(key: String) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        #if canImport(UIKit)
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        let id = UUID().uuidString
        #endif
        defaults.set(id, forKey: key)
        return id
    }
}
