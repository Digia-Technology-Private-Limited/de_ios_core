import Foundation

/// The live `SessionManager`, readable from any thread.
///
/// The network client exists before `initialize()` and outlives any one
/// `SDKServices`, so it cannot capture a session manager. It reads the
/// current session through this per request instead (D8): after a rotation,
/// the very next request carries the new ID.
final class CurrentSessionRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var manager: SessionManager?

    func set(_ manager: SessionManager?) {
        lock.withLock { self.manager = manager }
    }

    var sessionId: String? {
        lock.withLock { manager }?.sessionId
    }
}
