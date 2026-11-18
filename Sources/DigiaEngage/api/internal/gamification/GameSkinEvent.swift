import Foundation

/// A skin-defined game event (`event{name, props?}`). One fixed event name —
/// the skin's own `name` and `props` ride inside — with the campaign and skin
/// ids attached so the dashboard can attribute it.
struct GameSkinEvent: EngageAnalyticsEvent {
    let name: String
    let props: [String: Any]
    let campaignId: String
    let skinId: String
    let skinVersion: Int

    var eventName: String { "Digia Game Event" }

    var properties: [String: Any] {
        [
            "name": name,
            "props": props,
            "campaignId": campaignId,
            "skinId": skinId,
            "skinVersion": skinVersion,
        ]
    }
}
