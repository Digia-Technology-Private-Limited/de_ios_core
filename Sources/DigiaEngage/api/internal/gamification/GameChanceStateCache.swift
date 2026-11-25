import Foundation

/// The last terminal `state` answer per (campaignKey, chanceId), kept in
/// memory for the app session so the next open of the same chance can hand it
/// to the skin as `init.chanceState` and skip its open-time `state` call.
///
/// The stored value is the server's `data.response` unchanged: the exact
/// object the skin's own `state` bridge call resolves, so og-shim applies both
/// the same way. Only `played` answers are kept: a cached `playable` goes
/// stale the moment the chance is played through another surface (rewards
/// page, another entry), and the next open would wrongly offer play again.
/// A miss just costs one live state call.
final class GameChanceStateCache: @unchecked Sendable {
    static let shared = GameChanceStateCache()

    private let lock = NSLock()
    private var entries: [String: [String: Any]] = [:]

    /// Keeps `response` (a successful `state` call's `data.response`) when it
    /// is a `played` answer for a chance, replacing any older one.
    /// `playable` answers are deliberately never cached: they stop being true
    /// the moment the chance is played elsewhere, and a stale one makes the
    /// next open offer play on an already-played chance.
    func record(campaignKey: String, response: [String: Any]) {
        guard response["refused"] == nil || response["refused"] is NSNull,
              let state = response.nonBlankString("state"),
              state == "played",
              let chanceId = response.nonBlankString("chanceId"),
              JSONSerialization.isValidJSONObject(response)
        else { return }
        lock.lock()
        entries[Self.key(campaignKey, chanceId)] = response
        lock.unlock()
    }

    /// Drops every cached answer. Called on a user change next to the entry
    /// and storage clearing: without this a new user could receive the
    /// previous user's `chanceState`.
    func clearAll() {
        lock.lock()
        entries.removeAll()
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
