import Foundation

/// What the rewards page sends to the SDK. The wire format is the games
/// bridge's: a JSON string `{type, payload}`. `ready` is its own type; the
/// rest are `type: "action"` with `payload.op`.
enum RewardsPageMessage: Equatable {
    case ready
    case loadFailed
    case openGame(chanceId: String, campaignId: String)
    case openLink(String)
    case copy(String)
    case close
}

/// The rewards variant of the games bridge: parsing what the page sends and
/// building what the SDK pushes. Pure, so it is tested without a web view.
enum RewardsBridge {
    /// Facts the page needs to call the backend itself.
    struct Context: Equatable {
        let apiBase: String
        let projectId: String
        let userId: String
        let userHash: String?
        let platform: String
        let sdkVersion: String
        let appVersion: String
        let deviceId: String
        let locale: String
    }

    /// Parses one page message. Anything oversize, malformed or unknown is nil.
    static func parse(_ body: Any?) -> RewardsPageMessage? {
        guard let text = body as? String,
              text.utf8.count <= GameBridge.maxMessageBytes,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch type {
        case "ready":
            return .ready
        case "action":
            return parseAction(payload)
        default:
            return nil
        }
    }

    private static func parseAction(_ payload: [String: Any]) -> RewardsPageMessage? {
        switch payload["op"] as? String {
        case "loadFailed":
            return .loadFailed
        case "close":
            return .close
        case "openGame":
            guard let chanceId = nonBlank(payload["chanceId"]),
                  let campaignId = nonBlank(payload["campaignId"])
            else { return nil }
            return .openGame(chanceId: chanceId, campaignId: campaignId)
        case "openLink":
            return nonBlank(payload["url"]).map(RewardsPageMessage.openLink)
        case "copy":
            guard let text = payload["text"] as? String, !text.isEmpty else { return nil }
            return .copy(text)
        default:
            return nil
        }
    }

    private static func nonBlank(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// `{type:"init", payload}`. `userHash` is left out when the app set none.
    static func initMessage(_ context: Context) -> [String: Any] {
        var payload: [String: Any] = [
            "apiBase": context.apiBase,
            "projectId": context.projectId,
            "userId": context.userId,
            "platform": context.platform,
            "sdkVersion": context.sdkVersion,
            "appVersion": context.appVersion,
            "deviceId": context.deviceId,
            "locale": context.locale,
        ]
        if let userHash = context.userHash, !userHash.isEmpty { payload["userHash"] = userHash }
        return ["type": "init", "payload": payload]
    }

    static var refreshMessage: [String: Any] { ["type": "refresh", "payload": [String: Any]()] }

    /// The script that delivers `message` to `window.DigiaBridge.__receive`,
    /// the same double-encoding the games bridge uses.
    @MainActor
    static func script(for message: [String: Any]) -> String? {
        GameBridge.receiveScript(for: message)
    }

    /// A BCP-47 tag such as `en-US`, from the user's first preferred language.
    static func bcp47Locale(preferred: [String] = Locale.preferredLanguages) -> String {
        guard let first = preferred.first?.replacingOccurrences(of: "_", with: "-"),
              !first.isEmpty
        else { return "en-US" }
        return first
    }
}
