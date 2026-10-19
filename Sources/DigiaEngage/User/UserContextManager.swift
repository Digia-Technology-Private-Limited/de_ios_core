import Foundation

private let log = DigiaLogger("user")

private let attributesKey = "attributes"
private let contextKey = "context"
private let sentHashKey = "attributes_sent_hash"
/// The user the cached context and attributes describe.
private let ownerKey = "context_owner"

/// The context's life when the backend names none.
private let defaultExpirySeconds = 900

/// `value` as a typed attribute: a `String`, finite number, `Bool` or string
/// list. Anything else is nil and is dropped. Integers stay integers.
func attributeValue(_ value: Any?) -> Any? {
    switch value {
    case let string as String:
        return string
    case let number as NSNumber:
        // Bool bridges to NSNumber; keep it a boolean.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if CFNumberIsFloatType(number) { return number.doubleValue.isFinite ? number.doubleValue : nil }
        return number.intValue
    case let double as Double:
        return double.isFinite ? double : nil
    case let float as Float:
        return float.isFinite ? Double(float) : nil
    case let int as Int:
        return int
    case let bool as Bool:
        return bool
    case let list as [Any]:
        let strings = list.compactMap { $0 as? String }
        return strings.count == list.count ? strings : nil
    default:
        return nil
    }
}

private func typedAttributes(_ raw: Any?) -> [String: Any] {
    guard let map = raw as? [String: Any] else { return [:] }
    return map.compactMapValues(attributeValue)
}

/// `value` as text, for a campaign to interpolate.
func attributeText(_ value: Any) -> String {
    switch value {
    case let list as [String]: return "[\(list.joined(separator: ", "))]"
    default: return "\(value)"
    }
}

/// Everything the backend knows about the current user. One request carries
/// both directions: the app's attributes go up, the campaigns this user
/// qualifies for and the attributes to interpolate come back.
struct UserContext {
    var campaigns: [String]
    var attributes: [String: Any]
    var expiresAtMs: Int64

    func isExpired(nowMs: Int64) -> Bool { nowMs > expiresAtMs }

    var json: [String: Any] {
        ["campaigns": campaigns, "attributes": attributes, "expiresAtMs": expiresAtMs]
    }

    init(campaigns: [String], attributes: [String: Any], expiresAtMs: Int64) {
        self.campaigns = campaigns
        self.attributes = attributes
        self.expiresAtMs = expiresAtMs
    }

    init?(json: Any?) {
        guard let map = json as? [String: Any] else { return nil }
        campaigns = (map["campaigns"] as? [Any] ?? []).compactMap { $0 as? String }
        attributes = typedAttributes(map["attributes"])
        expiresAtMs = (map["expiresAtMs"] as? NSNumber)?.int64Value ?? 0
    }
}

/// The current user's server-side context and the attributes the host app
/// has set. Port of Flutter's `UserContextManager`; one instance per
/// ``SDKServices``.
@MainActor
final class UserContextManager {
    private let storage: LocalStorage
    private let networkClient: any NetworkClient
    private let nowMs: () -> Int64

    private var userId: String?
    /// Host-issued proof of `userId`.
    private var userHash: String?
    private var configured = false
    /// Whether this session already reported an unverified `userHash`.
    private var unverifiedReported = false

    /// The app's accumulated attributes. Calls merge into this rather than
    /// replacing it: no single call site knows the whole set.
    private(set) var attributes: [String: Any] = [:]
    private var context: UserContext?

    init(
        storage: LocalStorage,
        networkClient: any NetworkClient,
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.storage = storage
        self.networkClient = networkClient
        self.nowMs = nowMs
    }

    /// Whatever the backend merged, with any local change the backend has not
    /// seen yet layered on top. Rules compare these typed values.
    var resolvedValues: [String: Any] {
        (context?.attributes ?? [:]).merging(attributes) { _, local in local }
    }

    /// ``resolvedValues`` as text, for a campaign to interpolate.
    var resolvedAttributes: [String: String] { resolvedValues.mapValues(attributeText) }

    var eligibleCampaigns: [String] { context?.campaigns ?? [] }

    /// For the log: `missing`, `stale` or `fresh`.
    var contextState: String {
        guard let context else { return "missing" }
        return context.isExpired(nowMs: nowMs()) ? "stale" : "fresh"
    }

    /// Whether the cached context is gone or past its expiry.
    var needsRefresh: Bool {
        guard let context else { return true }
        return context.isExpired(nowMs: nowMs())
    }

    /// `restoredUserId` is whoever the SDK already knows about from a previous
    /// run: the host app does not call `setUserId` again on a relaunch.
    func configure(restoredUserId: String?, restoredUserHash: String? = nil) {
        configured = true
        userId = restoredUserId
        userHash = restoredUserId == nil ? nil : restoredUserHash
        if let owner = storage.string(forKey: ownerKey), owner != restoredUserId { clearCache() }
        if let restoredUserId { storage.set(restoredUserId, forKey: ownerKey) }
        attributes = readAttributes()
        context = readContext()
    }

    private func clearCache() {
        context = nil
        attributes = [:]
        for key in [contextKey, attributesKey, sentHashKey, ownerKey] { storage.remove(forKey: key) }
    }

    private func readAttributes() -> [String: Any] {
        guard let raw = storage.data(forKey: attributesKey),
              let json = try? JSONSerialization.jsonObject(with: raw) else { return [:] }
        return typedAttributes(json)
    }

    private func readContext() -> UserContext? {
        guard let raw = storage.data(forKey: contextKey),
              let json = try? JSONSerialization.jsonObject(with: raw) else { return nil }
        return UserContext(json: json)
    }

    /// Merges `new` into what we already hold and syncs if anything moved.
    ///
    /// Values are `String`, number, `Bool` or `[String]`. Others are dropped.
    func setUserAttributes(_ new: [String: Any]) async {
        let typed = typedAttributes(new)
        for key in new.keys.sorted() where typed[key] == nil {
            log.w("User attribute \"\(key)\" dropped — \(type(of: new[key] as Any)) is not String, number, Bool or [String]")
        }
        guard !typed.isEmpty else { return }
        log.i("User attributes set (\(typed.keys.sorted().joined(separator: ", ")))")
        attributes.merge(typed) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: attributes) {
            storage.set(data, forKey: attributesKey)
        }
        await refresh()
    }

    /// Drops the cached data of the previous user from memory at once. Call it
    /// before the identity changes, so no rule reads that data for `userId`.
    /// ``onUserIdChanged(_:userHash:)`` then clears the disk.
    func dropPreviousUser(_ userId: String?) {
        let previous = self.userId ?? storage.string(forKey: ownerKey)
        if let userId, userId == previous || previous == nil { return }
        // A nil user also discards a fetch still in flight for the previous one.
        self.userId = nil
        userHash = nil
        context = nil
        attributes = [:]
    }

    /// Called when the host app identifies a user, or clears it.
    func onUserIdChanged(_ userId: String?, userHash: String? = nil) async {
        // Before configure, the stored owner is the only record of the last user.
        let previous = self.userId ?? storage.string(forKey: ownerKey)
        let userChanged = userId != previous
        if userChanged { unverifiedReported = false }
        let changed = userChanged || userHash != self.userHash
        self.userId = userId
        self.userHash = userId == nil ? nil : userHash
        if userId == nil || (userChanged && previous != nil) {
            // The context and the attributes describe the previous user. Keeping
            // either would let the next user inherit their targeting. Attributes
            // set before the first login stay: they describe the user who logs in.
            clearCache()
        }
        guard let userId else { return }
        storage.set(userId, forKey: ownerKey)
        await refresh(force: changed)
    }

    /// A stable fingerprint of what we last sent. Sorted, so a reordered map
    /// is not mistaken for a change.
    private func fingerprint(_ attributes: [String: Any]) -> String {
        attributes.keys.sorted().map { key in
            let data = try? JSONSerialization.data(withJSONObject: attributes[key] as Any, options: .fragmentsAllowed)
            return "\(key)=\(data.flatMap { String(data: $0, encoding: .utf8) } ?? "")"
        }.joined(separator: "|")
    }

    /// Fetches the context, skipping the call when there is nothing to learn:
    /// a user whose attributes have not changed and whose cached context is
    /// still valid makes no request.
    func refresh(force: Bool = false) async {
        guard configured, let userId, let url = URL(string: DigiaEndpoints.userContext) else { return }

        let hash = fingerprint(attributes)
        let attributesChanged = hash != storage.string(forKey: sentHashKey)
        let contextUsable = context.map { !$0.isExpired(nowMs: nowMs()) } ?? false
        if !force && !attributesChanged && contextUsable { return }

        var body: [String: Any] = ["userId": userId]
        // The whole accumulated map, not a delta: a failed send is corrected by
        // the next one rather than leaving a key permanently missing.
        if attributesChanged || force { body["attributes"] = attributes }
        if let userHash { body["userHash"] = userHash }

        do {
            let request = NetworkRequest(
                url: url,
                method: .post,
                headers: ["Content-Type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: body),
                connectTimeout: 10,
                readTimeout: 10
            )
            let response = try await networkClient.execute(request: request)

            // The user changed while the request was out: this answer is not theirs.
            guard self.userId == userId else { return }

            guard response.statusCode == 200 else {
                log.w(
                    "User context fetch failed — HTTP \(response.statusCode)",
                    stage: .session,
                    reason: TimelineReason.userContextFailed,
                    extras: ["http_status": "\(response.statusCode)"]
                )
                return
            }
            guard let payload = Self.payload(of: response.body) else { return }

            let dropped = (payload["droppedAttributes"] as? [Any] ?? []).compactMap { $0 as? String }
            if !dropped.isEmpty {
                // A warning: a silently missing variable renders as its fallback
                // and looks like nothing is wrong.
                log.w("User attributes rejected by the server: \(dropped.joined(separator: ", "))")
            }
            if userHash != nil, payload["verified"] as? Bool == false, !unverifiedReported {
                unverifiedReported = true
                log.d(
                    "userHash not verified — imported attributes are withheld",
                    stage: .session,
                    reason: TimelineReason.userHashUnverified
                )
            }
            let ttl = (payload["expiresInSeconds"] as? NSNumber)?.intValue ?? defaultExpirySeconds
            let fresh = UserContext(
                campaigns: (payload["campaigns"] as? [Any] ?? []).compactMap { $0 as? String },
                attributes: typedAttributes(payload["attributes"]),
                expiresAtMs: nowMs() + Int64(ttl) * 1000
            )
            context = fresh
            log.d("User context ready (campaigns=\(fresh.campaigns.count), attributes=\(fresh.attributes.count))")
            if let data = try? JSONSerialization.data(withJSONObject: fresh.json) {
                storage.set(data, forKey: contextKey)
            }
            storage.set(hash, forKey: sentHashKey)
        } catch {
            // The cached copy is kept: an expired context on a dead network is
            // better than none.
            log.w(
                "User context fetch failed — continuing with the cached copy",
                error: error.localizedDescription,
                stage: .session,
                reason: TimelineReason.userContextFailed,
                extras: ["cause": String(describing: type(of: error))]
            )
        }
    }

    /// Unwraps the `{isSuccess, data: {response}}` envelope every Engage SDK
    /// endpoint replies with, tolerating a bare body so a shape change degrades
    /// to reading what is there. Mirrors the campaign fetcher.
    private static func payload(of body: Data?) -> [String: Any]? {
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let data = json["data"] as? [String: Any], let response = data["response"] { return response as? [String: Any] }
        if let response = json["response"] { return response as? [String: Any] }
        return json
    }
}
