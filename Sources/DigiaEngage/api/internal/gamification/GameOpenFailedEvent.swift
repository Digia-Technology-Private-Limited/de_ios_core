import Foundation

/// A game that failed on the client before it showed, forwarded to Digia
/// analytics. `reason` is a `GameFailureReason` wire value, `skin_unavailable` for a
/// failed skin download, or `error` for a failed play. Never sent for a busy,
/// denied or not-shown drop, nor once the game has shown. A live test's
/// payload suppresses it, like every other analytics event.
struct GameOpenFailedEvent: EngageAnalyticsEvent {
    let reason: String
    let chanceId: String
    let entry: String
    let skinId: String
    let skinVersion: Int
    /// `game`, `engine` or `none`: what the prewarm had ready for this open.
    var warm: String? = nil
    /// The device tier; nil when it cannot be read.
    var tier: String? = nil
    /// Milliseconds from the intent to the failure; 0 for an entry tap.
    var msElapsed: Int64? = nil
    /// How far the open got: `grant`, `download`, `load`, `commit` or `ready`.
    var stage: String? = nil

    var eventName: String { "game_open_failed" }

    var properties: [String: Any] {
        var properties: [String: Any] = [
            "reason": reason,
            "chance_id": chanceId,
            "entry": entry,
            "skin_id": skinId,
            "skin_version": skinVersion,
        ]
        if let warm { properties["warm"] = warm }
        if let tier { properties["tier"] = tier }
        if let msElapsed { properties["ms_elapsed"] = msElapsed }
        if let stage { properties["stage"] = stage }
        return properties
    }
}
