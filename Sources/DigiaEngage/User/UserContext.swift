import Foundation

struct UserContext {
    let campaigns: [String]
    let attributes: [String: String]
    let expiresAtMs: Int64

    var isExpired: Bool { Int64(Date().timeIntervalSince1970 * 1_000) > expiresAtMs }

    func toJson() -> [String: Any] {
        ["campaigns": campaigns, "attributes": attributes, "expiresAtMs": expiresAtMs]
    }

    static func stringList(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    static func stringMap(_ value: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in (value as? [String: Any] ?? [:]) { out[k] = "\(v)" }
        return out
    }

    static func fromJson(_ json: [String: Any]) -> UserContext? {
        let campaigns = stringList(json["campaigns"])
        let attributes = stringMap(json["attributes"])
        guard let expires = (json["expiresAtMs"] as? NSNumber)?.int64Value ?? json["expiresAtMs"] as? Int64 else { return nil }
        return UserContext(campaigns: campaigns, attributes: attributes, expiresAtMs: expires)
    }
}
