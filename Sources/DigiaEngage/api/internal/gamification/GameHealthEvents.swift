import Foundation

/// The campaign facts every `game_` health event carries. `entry` is
/// `direct`, `inlineTeaser`, `floating` or `rewards`.
struct GameHealthContext: Equatable, Sendable {
    let campaignId: String
    let skinId: String
    let skinVersion: Int
    let entry: String

    var properties: [String: Any] {
        [
            "campaignId": campaignId,
            "skinId": skinId,
            "skinVersion": skinVersion,
            "entry": entry,
        ]
    }
}

/// A skin `http` request failed. `code` is the bridge error code, `status`
/// the HTTP status when the server answered, `durationMs` the call's wall time.
struct GameHttpFailedEvent: EngageAnalyticsEvent {
    let health: GameHealthContext
    let method: String
    let path: String
    let code: String
    let status: Int?
    let durationMs: Int

    var eventName: String { "game_http_failed" }

    var properties: [String: Any] {
        var merged = health.properties
        merged["method"] = method
        merged["path"] = path
        merged["code"] = code
        if let status { merged["status"] = status }
        merged["durationMs"] = durationMs
        return merged
    }
}

/// A rewards fetch failed, or the post-close state check failed. `op` is
/// `rewards` or `state`; `code` is `network`, `timeout`, `invalid_response`
/// or `status` (with the HTTP status beside it).
struct GameRewardsFailedEvent: EngageAnalyticsEvent {
    let health: GameHealthContext
    let op: String
    let code: String
    let status: Int?
    let durationMs: Int

    var eventName: String { "game_rewards_failed" }

    var properties: [String: Any] {
        var merged = health.properties
        merged["op"] = op
        merged["code"] = code
        if let status { merged["status"] = status }
        merged["durationMs"] = durationMs
        return merged
    }
}

/// The skin logged at `error` level. At most 5 per open; `message` is
/// truncated to 500 characters.
struct GameSkinErrorEvent: EngageAnalyticsEvent {
    let health: GameHealthContext
    let message: String

    var eventName: String { "game_skin_error" }

    var properties: [String: Any] {
        var merged = health.properties
        merged["message"] = String(message.prefix(500))
        return merged
    }
}

/// The first malformed message of an open, sent once. `reason` is `oversize`,
/// `malformed` or `unknown`; `type` rides only when a request type was read.
struct GameBridgeDroppedEvent: EngageAnalyticsEvent {
    let health: GameHealthContext
    let reason: String
    let type: String?

    var eventName: String { "game_bridge_dropped" }

    var properties: [String: Any] {
        var merged = health.properties
        merged["reason"] = reason
        if let type { merged["type"] = type }
        return merged
    }
}
