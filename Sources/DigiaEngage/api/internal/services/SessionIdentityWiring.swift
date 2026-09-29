import Foundation

/// The session-and-identity rules that connect already-built collaborators.
/// Not tied to the main actor, so it can be exercised without `SDKServices`.
struct SessionIdentityWiring {
    let identityManager: IdentityManager
    let sessionManager: SessionManager
    /// Nil when sessions are not reported. Session telemetry is analytics:
    /// opting out of one stops the other.
    let sessionReporter: SessionReporter?

    /// Installs the listeners, in this order:
    /// 1. a new or cleared user starts a new session (D2), whatever the
    ///    analytics setting;
    /// 2. a session rotation sends a session report, only when a reporter is
    ///    given. Without one the session still rotates (D2); it just isn't
    ///    reported.
    func attach() {
        identityManager.addUserChangedListener { [weak sessionManager] in
            sessionManager?.reset()
        }
        if let sessionReporter {
            sessionManager.addRotationListener { [weak sessionReporter] in
                sessionReporter?.report()
            }
        }
    }
}
