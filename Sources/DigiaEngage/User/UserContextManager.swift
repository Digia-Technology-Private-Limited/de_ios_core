import CryptoKit
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

/// A short digest of `userId`: lets the health sink tell one user's
/// `user_hash_unverified` from another's without the id itself leaving the
/// manager. Dedup only; never health detail.
private func userRef(_ userId: String) -> String {
    String(SHA256.hash(data: Data(userId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
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

    /// Called when a refresh that holds gated campaigns starts its request; the
    /// closure it returns is called when that request ends, however it ends.
    var onFetchStarted: (() -> () -> Void)?

    /// A wait opened by ``holdForRefresh()``, taken over by the next
    /// ``refresh(force:holdsCampaigns:)`` that has a user, or released by the
    /// last ``releaseUnusedHold()``.
    private var pendingHold: (() -> Void)?

    /// How many callers of ``holdForRefresh()`` have not yet released. The wait
    /// ends only when all have, so one caller cannot end the wait another
    /// opened for a user change still on its way.
    private var holders = 0

    /// Opens the wait for gated campaigns now, ahead of the refresh that will
    /// end it, so a trigger sent before that refresh starts is still held.
    func holdForRefresh() {
        holders += 1
        if pendingHold == nil { pendingHold = onFetchStarted?() }
    }

    /// Ends a wait that no refresh took over, once every holder has released.
    func releaseUnusedHold() {
        if holders > 0 { holders -= 1 }
        if holders > 0 { return }
        let end = pendingHold
        pendingHold = nil
        end?()
    }

    private var userId: String?
    /// Host-issued proof of `userId`.
    private var userHash: String?
    private var configured = false
    /// Whether this session already reported an unverified `userHash`.
    private var unverifiedReported = false
    /// Whether this session already reported `userId` as identified without a hash.
    private var missingHashReported = false

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
        announced = false
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
        guard mergeAttributes(new) else { return }
        holdForRefresh()
        defer { releaseUnusedHold() }
        await refresh()
    }

    /// The synchronous half of ``setUserAttributes(_:)``: rules read the merged
    /// attributes as soon as this returns. False when nothing was storable.
    func mergeAttributes(_ new: [String: Any]) -> Bool {
        let typed = typedAttributes(new)
        for key in new.keys.sorted() where typed[key] == nil {
            log.w("User attribute \"\(key)\" dropped — \(type(of: new[key] as Any)) is not String, number, Bool or [String]")
        }
        guard !typed.isEmpty else { return false }
        log.i("User attributes set (\(typed.keys.sorted().joined(separator: ", ")))")
        attributes.merge(typed) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: attributes) {
            storage.set(data, forKey: attributesKey)
        }
        return true
    }

    /// Drops the cached data of the previous user from memory at once. Call it
    /// before the identity changes, so no rule reads that data for `userId`.
    /// ``onUserIdChanged(_:userHash:)`` then clears the disk.
    func dropPreviousUser(_ userId: String?) {
        announced = true
        announcedUserId = userId
        let previous = self.userId ?? storage.string(forKey: ownerKey)
        if let userId, userId == previous || previous == nil { return }
        // A nil user also discards a fetch still in flight for the previous one.
        self.userId = nil
        userHash = nil
        context = nil
        attributes = [:]
    }

    /// The user the host app asked for last. A user change still on its way for
    /// anyone else is out of date, and applying it would hand that user the
    /// attributes the host app has just set for the current one.
    private var announced = false
    private var announcedUserId: String?

    /// Called when the host app identifies a user, or clears it.
    func onUserIdChanged(_ userId: String?, userHash: String? = nil) async {
        if announced && announcedUserId != userId { return }
        // Before configure, the stored owner is the only record of the last user.
        let previous = self.userId ?? storage.string(forKey: ownerKey)
        let userChanged = userId != previous
        if userChanged {
            unverifiedReported = false
            missingHashReported = false
        }
        let changed = userChanged || userHash != self.userHash
        // No user in memory means `dropPreviousUser` already emptied it, so what
        // the attributes hold now was set after the switch: it is the new user's.
        let keptAttributes = self.userId == nil ? attributes : [:]
        self.userId = userId
        self.userHash = userId == nil ? nil : userHash
        if userId == nil || (userChanged && previous != nil) {
            // The context and the attributes describe the previous user. Keeping
            // either would let the next user inherit their targeting. Attributes
            // set before the first login stay: they describe the user who logs in.
            clearCache()
            if userId != nil, !keptAttributes.isEmpty {
                attributes = keptAttributes
                if let data = try? JSONSerialization.data(withJSONObject: attributes) {
                    storage.set(data, forKey: attributesKey)
                }
            }
        }
        guard let userId else { return }
        if (userHash ?? "").isEmpty, !missingHashReported {
            missingHashReported = true
            log.d(
                "userId set without a userHash — imported attributes are withheld",
                stage: .session,
                reason: TimelineReason.userHashUnverified,
                extras: ["cause": "missing_hash", "user_ref": userRef(userId)]
            )
        }
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
    ///
    /// `holdsCampaigns` is false for a refresh that must not make an
    /// `audienceGated` campaign wait, such as the one on return to the app.
    func refresh(force: Bool = false, holdsCampaigns: Bool = true) async {
        // A wait opened ahead of this call is ended by it, fetch or not.
        // Only a refresh that has a user can end it: without one it fetches
        // nothing, and the wait belongs to the refresh of the user about to be set.
        let opened = userId == nil ? nil : pendingHold
        if opened != nil { pendingHold = nil }
        defer { opened?() }
        await refreshNow(force: force, holdsCampaigns: holdsCampaigns && opened == nil)
    }

    private func refreshNow(force: Bool, holdsCampaigns: Bool) async {
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

        let fetchEnded = holdsCampaigns ? onFetchStarted?() : nil
        defer { fetchEnded?() }
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
            if userHash != nil, ruleIsBool(payload["verified"]), payload["verified"] as? Bool == false, !unverifiedReported {
                unverifiedReported = true
                log.d(
                    "userHash not verified — imported attributes are withheld",
                    stage: .session,
                    reason: TimelineReason.userHashUnverified,
                    extras: ["cause": "server_unverified", "user_ref": userRef(userId)]
                )
            }
            let ttl = Self.expirySeconds(payload["expiresInSeconds"])
            let fresh = UserContext(
                campaigns: (payload["campaigns"] as? [Any] ?? []).compactMap { $0 as? String },
                attributes: typedAttributes(payload["attributes"]),
                expiresAtMs: nowMs() + ttl * 1000
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

    /// The context's lifetime. A JSON number only (a boolean is not one), whole
    /// seconds; a value no real clock reaches falls back to the default, so the
    /// millisecond arithmetic cannot overflow.
    static func expirySeconds(_ raw: Any?) -> Int64 {
        let limit = 3_153_600_000.0  // 100 years
        guard let seconds = ruleJSONNumber(raw), seconds.isFinite, abs(seconds) <= limit else {
            return Int64(defaultExpirySeconds)
        }
        return Int64(seconds)
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
