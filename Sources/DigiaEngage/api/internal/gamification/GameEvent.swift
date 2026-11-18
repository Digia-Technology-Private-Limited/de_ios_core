import Foundation

/// The game funnel, reported like every other campaign type: a Viewed when the
/// game surface shows, a Clicked on a skin CTA op (with the tapped `element`),
/// and a Dismissed when the game closes (`user`, `skin`, `cta` or `failure`).
/// Same event names as every other type, so the backend funnels read games
/// without a new case. Mirrors Android's `GameEvent`.
enum GameEvent {
    struct Viewed: EngageAnalyticsEvent {
        var eventName: String { "Digia Experience Viewed" }

        var properties: [String: Any] { [:] }
    }

    struct Clicked: EngageAnalyticsEvent {
        let element: String

        var eventName: String { "Digia Experience Clicked" }

        var properties: [String: Any] { ["element": element] }
    }

    struct Dismissed: EngageAnalyticsEvent {
        let reason: String

        var eventName: String { "Digia Experience Dismissed" }

        var properties: [String: Any] { ["dismiss_reason": reason] }
    }
}
