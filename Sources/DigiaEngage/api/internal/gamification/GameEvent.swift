import Foundation

/// The game funnel, reported like every other campaign type: one Viewed when the
/// game surface first shows, a Clicked for each `/play` the skin sends
/// (`element_id` is `play` for the window's first play, `play_again` after; Digia
/// only, never a CEP click), and one Dismissed when the window closes after
/// showing (`user`, `skin`, `cta` or `failure`). Same event names as every other
/// type, so the backend funnels read games without a new case. `chance_id` is
/// always the chance the window opened with. `entry` is where the window opened:
/// `direct`, `inlineTeaser`, `floating` or `rewards`, the value the health events
/// send; left off the wire when nil. A rewards open still rides its synthetic
/// `rewards:<chanceId>` payload; `entry` sits beside it. Mirrors Android's `GameEvent`.
enum GameEvent {
    static let displayStyle = "game"

    struct Viewed: EngageAnalyticsEvent {
        let chanceId: String
        let skinId: String
        let skinVersion: Int
        /// `game`, `engine` or `none`: what the prewarm had ready for this open.
        var warm: String? = nil
        /// The device tier; nil when it cannot be read.
        var tier: String? = nil
        /// Milliseconds from the intent (trigger or tap) to `ready`.
        var msToReady: Int64? = nil
        var entry: String? = nil

        var eventName: String { "Digia Experience Viewed" }

        var properties: [String: Any] {
            var properties: [String: Any] = [
                "display_style": GameEvent.displayStyle,
                "chance_id": chanceId,
                "skin_id": skinId,
                "skin_version": skinVersion,
            ]
            if let warm { properties["warm"] = warm }
            if let tier { properties["tier"] = tier }
            if let msToReady { properties["ms_to_ready"] = msToReady }
            if let entry { properties["entry"] = entry }
            return properties
        }
    }

    struct Clicked: EngageAnalyticsEvent {
        let elementId: String
        let chanceId: String
        /// The link a skin `openLink` CTA opened; left off the wire otherwise.
        var actionUrl: String? = nil
        var entry: String? = nil

        var eventName: String { "Digia Experience Clicked" }

        var properties: [String: Any] {
            var properties: [String: Any] = [
                "display_style": GameEvent.displayStyle,
                "element_id": elementId,
                "chance_id": chanceId,
            ]
            if let actionUrl { properties["action_url"] = actionUrl }
            if let entry { properties["entry"] = entry }
            return properties
        }
    }

    /// `playRefused` is the last refusal reason the server gave, left off the
    /// wire when none.
    struct Dismissed: EngageAnalyticsEvent {
        let reason: String
        let dwellMs: Int64
        let chanceId: String
        let skinId: String
        let skinVersion: Int
        let plays: Int
        let playRefused: String
        var entry: String? = nil

        var eventName: String { "Digia Experience Dismissed" }

        var properties: [String: Any] {
            var out: [String: Any] = [
                "display_style": GameEvent.displayStyle,
                "dismiss_reason": reason,
                "dwell_ms": dwellMs,
                "chance_id": chanceId,
                "skin_id": skinId,
                "skin_version": skinVersion,
                "plays": plays,
            ]
            if !playRefused.isEmpty { out["play_refused"] = playRefused }
            if let entry { out["entry"] = entry }
            return out
        }
    }
}
