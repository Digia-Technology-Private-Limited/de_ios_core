import Foundation

let userContextTTLSeconds: Int64 = 900

@MainActor
final class UserContextManager {
    private let defaults: UserDefaults
    var httpPost: ((String, Data, [String: String]) async throws -> (Int, Data?))?

    private var apiKey: String?
    private var userId: String?
    private var attributes: [String: String] = [:]
    private var context: UserContext?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var eligibleCampaigns: [String] { context?.campaigns ?? [] }
    var resolvedAttributes: [String: String] { (context?.attributes ?? [:]).merging(attributes) { _, local in local } }

    func configure(apiKey: String, restoredUserId: String?) {
        self.apiKey = apiKey
        self.userId = restoredUserId
        self.attributes = readAttributes()
        self.context = readContext()
    }

    func setUserAttributes(_ newAttributes: [String: String]) {
        guard !newAttributes.isEmpty else { return }
        attributes.merge(newAttributes) { _, new in new }
        persistAttributes()
        Task { await refresh() }
    }

    func onUserIdChanged(_ newUserId: String?) {
        let previous = userId
        userId = newUserId
        if newUserId == previous {
            // Same id re-stated (e.g. every cold start): previous behavior.
            if newUserId != nil { Task { await refresh(force: true) } }
            return
        }
        // Identity actually changed: drop the cached context; a stale
        // eligibility list must never gate the new user.
        context = nil
        defaults.removeObject(forKey: Self.keyContext)
        if previous != nil {
            // A→nil or A→B: A's attributes describe someone else now. Kept
            // only for nil→X, where pre-login attributes await their owner.
            attributes = [:]
            defaults.removeObject(forKey: Self.keyAttributes)
            defaults.removeObject(forKey: Self.keySentHash)
        }
        if newUserId != nil { Task { await refresh(force: true) } }
    }

    func refresh(force: Bool = false) async {
        guard let uid = userId, let key = apiKey else { return }
        let hash = fingerprint(attributes)
        let changed = hash != defaults.string(forKey: Self.keySentHash)
        let usable = context.map { !$0.isExpired } ?? false
        if !force && !changed && usable { return }
        do {
            var body: [String: Any] = ["userId": uid]
            if changed || force { body["attributes"] = attributes }
            let data = try JSONSerialization.data(withJSONObject: body)
            let headers = ["Content-Type": "application/json", "X-Digia-Project-Id": key]
            let (status, responseData): (Int, Data?)
            if let httpPost { (status, responseData) = try await httpPost(DigiaEndpoints.userContext, data, headers) }
            else {
                guard let url = URL(string: DigiaEndpoints.userContext) else { return }
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.httpMethod = "POST"
                for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
                request.httpBody = data
                let (respData, response) = try await URLSession.shared.data(for: request)
                (status, responseData) = ((response as? HTTPURLResponse)?.statusCode ?? 0, respData)
            }
            guard status == 200, let responseData,
                  let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let payload = payloadOf(json) else {
                DigiaLog.log("context fetch failed: HTTP \(status)", tag: "Digia")
                return
            }
            let dropped = UserContext.stringList(payload["droppedAttributes"])
            if !dropped.isEmpty { DigiaLog.warning("attributes rejected by the server: \(dropped.joined(separator: ", "))") }
            let ttl = (payload["expiresInSeconds"] as? NSNumber)?.int64Value ?? userContextTTLSeconds
            let next = UserContext(
                campaigns: UserContext.stringList(payload["campaigns"]),
                attributes: UserContext.stringMap(payload["attributes"]),
                expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + max(ttl, 1) * 1_000)
            context = next
            if let ctx = try? JSONSerialization.data(withJSONObject: next.toJson()) {
                defaults.set(String(data: ctx, encoding: .utf8), forKey: Self.keyContext)
            }
            defaults.set(hash, forKey: Self.keySentHash)
        } catch {
            DigiaLog.log("context fetch failed: \(error.localizedDescription)", tag: "Digia")
        }
    }

    private func fingerprint(_ attrs: [String: String]) -> String {
        attrs.keys.sorted().map { "\($0)=\(attrs[$0] ?? "")" }.joined(separator: "|")
    }

    private func readAttributes() -> [String: String] {
        guard let raw = defaults.string(forKey: Self.keyAttributes),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj { out[k] = "\(v)" }
        return out
    }

    private func readContext() -> UserContext? {
        guard let raw = defaults.string(forKey: Self.keyContext),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return UserContext.fromJson(obj)
    }

    private func persistAttributes() {
        if let data = try? JSONSerialization.data(withJSONObject: attributes) {
            defaults.set(String(data: data, encoding: .utf8), forKey: Self.keyAttributes)
        }
    }

    private func payloadOf(_ body: [String: Any]) -> [String: Any]? {
        if let response = (body["data"] as? [String: Any])?["response"] as? [String: Any] { return response }
        if let response = body["response"] as? [String: Any] { return response }
        return body["campaigns"] != nil ? body : nil
    }

    private static let keyAttributes = "user_attributes"
    private static let keyContext = "user_context"
    private static let keySentHash = "user_attributes_sent_hash"
}
