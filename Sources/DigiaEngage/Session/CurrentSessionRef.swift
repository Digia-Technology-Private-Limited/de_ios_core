import Foundation

/// The live `SessionManager` and SDK request headers, readable from any thread.
///
/// The network client exists before `initialize()` and outlives any one
/// `SDKServices`, so it cannot capture them. It reads the current session
/// through this per request instead (D8): after a rotation, the very next
/// request carries the new ID. The request headers (Project-Id, Device-Id,
/// environment, SDK version) are read the same way, so call sites pass only
/// their protocol headers. `X-Digia-User-Id` and `X-Digia-User-Hash` are added
/// from the live `IdentityManager` while a user is set, as Android and
/// Flutter do. Neither ever reaches a skin: the bridge sends only headers,
/// never body fields the skin could read.
final class CurrentSessionRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var manager: SessionManager?
    private weak var identity: IdentityManager?
    private var headers: [String: String] = [:]

    func set(_ manager: SessionManager?, identity: IdentityManager? = nil, requestHeaders: [String: String]) {
        lock.withLock {
            self.manager = manager
            self.identity = identity
            self.headers = requestHeaders
        }
    }

    var sessionId: String? {
        lock.withLock { manager }?.sessionId
    }

    var requestHeaders: [String: String] {
        let (headers, identity) = lock.withLock { (self.headers, self.identity) }
        guard let userId = identity?.userId, !userId.isEmpty else { return headers }
        var out = headers.merging(["X-Digia-User-Id": userId]) { _, new in new }
        if let userHash = identity?.userHash, !userHash.isEmpty {
            out["X-Digia-User-Hash"] = userHash
        }
        return out
    }
}
