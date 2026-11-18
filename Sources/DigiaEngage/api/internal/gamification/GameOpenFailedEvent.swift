import Foundation

/// A game that failed on the client before it showed, forwarded to Digia
/// analytics. `reason` is a `GameFailure` wire value, `skin_unavailable` for a
/// failed skin download, or `error` for a failed play. Never sent for a busy,
/// denied or not-shown drop, nor once the game has shown. A live test's
/// payload suppresses it, like every other analytics event.
struct GameOpenFailedEvent: EngageAnalyticsEvent {
    let reason: String
    let chanceId: String
    let entry: String
    let skinId: String
    let skinVersion: Int

    var eventName: String { "game_open_failed" }

    var properties: [String: Any] {
        [
            "reason": reason,
            "chance_id": chanceId,
            "entry": entry,
            "skin_id": skinId,
            "skin_version": skinVersion,
        ]
    }
}
