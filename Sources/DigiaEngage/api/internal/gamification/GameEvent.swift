import Foundation

/// The game funnel, reported like every other campaign type: a Viewed when the
/// game surface shows, a Clicked on a skin CTA op (`element_id` is the op), and
/// a Dismissed when the game closes (`user`, `skin`, `cta` or `failure`). Same
/// event names as every other type, so the backend funnels read games without
/// a new case. Mirrors Android's `GameEvent`.
enum GameEvent {
    static let displayStyle = "game"

    struct Viewed: EngageAnalyticsEvent {
        let chanceId: String
        let skinId: String
        let skinVersion: Int

        var eventName: String { "Digia Experience Viewed" }

        var properties: [String: Any] {
            [
                "display_style": GameEvent.displayStyle,
                "chance_id": chanceId,
                "skin_id": skinId,
                "skin_version": skinVersion,
            ]
        }
    }

    struct Clicked: EngageAnalyticsEvent {
        let elementId: String
        let chanceId: String

        var eventName: String { "Digia Experience Clicked" }

        var properties: [String: Any] {
            [
                "display_style": GameEvent.displayStyle,
                "element_id": elementId,
                "chance_id": chanceId,
            ]
        }
    }

    struct Dismissed: EngageAnalyticsEvent {
        let reason: String
        let dwellMs: Int64
        let chanceId: String
        let skinId: String
        let skinVersion: Int
        let plays: Int
        let playRefused: String

        var eventName: String { "Digia Experience Dismissed" }

        var properties: [String: Any] {
            [
                "display_style": GameEvent.displayStyle,
                "dismiss_reason": reason,
                "dwell_ms": dwellMs,
                "chance_id": chanceId,
                "skin_id": skinId,
                "skin_version": skinVersion,
                "plays": plays,
                "play_refused": playRefused,
            ]
        }
    }
}
