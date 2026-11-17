import Foundation

/// A game that never opened, forwarded to Digia analytics. `reason` is one of
/// the `PlayDropReason` strings, a `GameFailure` wire value, or
/// `skin_unavailable` for a failed skin download; `denyReason` rides only
/// when the server sent one. A live test's payload suppresses it, like every
/// other analytics event.
struct GameOpenFailedEvent: EngageAnalyticsEvent {
    let reason: String
    let denyReason: String?

    var eventName: String { "game_open_failed" }

    var properties: [String: Any] {
        nonNull([("reason", reason), ("deny_reason", denyReason)])
    }
}
