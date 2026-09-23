import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class AnalyticsIdentityManager {
    let identityManager: IdentityManager
    private var _sessionId: String = ""
    private var _lastEventDate: Date?
    private var _sessionTimeoutMs: Int = 30 * 60 * 1_000

    /// Called whenever the session ID rotates. Wired by AnalyticsService to report the new session.
    var onSessionRotated: (() -> Void)?

    init(identityManager: IdentityManager) {
        self.identityManager = identityManager
    }

    convenience init(storage: LocalStorage = UserDefaultsLocalStorage().scoped("identity")) {
        self.init(identityManager: IdentityManager(storage: storage))
    }

    convenience init(defaults: UserDefaults) {
        self.init(storage: UserDefaultsLocalStorage(defaults: defaults).scoped("identity"))
    }

    var anonymousId: String { identityManager.getDeviceId() }
    var userId: String? { identityManager.getUserId() }
    var sessionId: String { _sessionId }

    func resolveAnonymousId() -> String { identityManager.getDeviceId() }

    func initialize(sessionTimeoutMs: Int) {
        _sessionTimeoutMs = sessionTimeoutMs
        _sessionId = UUID().uuidString
        _lastEventDate = Date()
    }

    func setUserId(_ userId: String) {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard identityManager.getUserId() != trimmed else { return }
        identityManager.setUserId(trimmed)
        rotateSession()
    }

    func clearUserId() {
        guard identityManager.getUserId() != nil else { return }
        identityManager.clearUserId()
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
}
