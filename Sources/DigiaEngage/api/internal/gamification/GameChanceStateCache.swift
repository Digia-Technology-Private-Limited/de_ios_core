import Foundation

/// The last successful `state` answer per (campaignKey, chanceId), kept in
/// memory for the app session so the next open of the same chance can hand it
/// to the skin as `init.chanceState` and skip its open-time `state` call (see
/// ai_docs/gamification/eng/sdk/init-chance-state-contract.md).
///
/// The stored value is the server's `data.response` unchanged: the exact
/// object the skin's own `state` bridge call resolves, so og-shim applies both
/// the same way. Only `playable`/`played` answers carry a `chanceId`, so only
/// they can match an init; everything else is ignored.
final class GameChanceStateCache: @unchecked Sendable {
    static let shared = GameChanceStateCache()

    private let lock = NSLock()
    private var entries: [String: [String: Any]] = [:]

    /// Keeps `response` (a successful `state` call's `data.response`) when it
    /// is a playable or played answer for a chance, replacing any older one.
    func record(campaignKey: String, response: [String: Any]) {
        guard response["refused"] == nil || response["refused"] is NSNull,
              let state = response.nonBlankString("state"),
              state == "playable" || state == "played",
              let chanceId = response.nonBlankString("chanceId"),
              JSONSerialization.isValidJSONObject(response)
        else { return }
        lock.lock()
        entries[Self.key(campaignKey, chanceId)] = response
        lock.unlock()
    }

    func lookup(campaignKey: String, chanceId: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Self.key(campaignKey, chanceId)]
    }

    private static func key(_ campaignKey: String, _ chanceId: String) -> String {
        "\(campaignKey)\u{0}\(chanceId)"
    }
}
