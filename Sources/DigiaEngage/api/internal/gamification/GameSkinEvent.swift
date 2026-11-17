import Foundation

/// A skin `event` forwarded to Digia analytics.
///
/// The skin's `name` is the event name; the skin's `props` plus the chance,
/// skin, and skin-version identity ride as properties. Campaign id and type
/// resolve from the store, like every other campaign event.
struct GameSkinEvent: EngageAnalyticsEvent {
    let name: String
    let skinId: String
    let skinVersion: Int
    let chanceId: String
    let props: [String: Any]

    var eventName: String { name }

    var properties: [String: Any] {
        var merged = props
        merged["skin_id"] = skinId
        merged["skin_version"] = skinVersion
        merged["chance_id"] = chanceId
        return merged
    }
}
