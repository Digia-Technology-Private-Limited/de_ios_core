import Foundation

enum EngageAction: Equatable {
    case openUrl(String)
    case openDeeplink(String)
    case copyToClipboard(String)
    case share(String)
    case customKV([String: String])
    case dismiss
    case next
    case previous
    case requestReview

    var analyticsType: String {
        switch self {
        case .openUrl: "url"
        case .openDeeplink: "deeplink"
        case .copyToClipboard: "copy"
        case .share: "share"
        case .customKV: "customKV"
        case .dismiss: "dismiss"
        case .next: "next"
        case .previous: "previous"
        case .requestReview: "request_review"
        }
    }

    var analyticsURL: String? {
        switch self {
        case .openUrl(let url), .openDeeplink(let url): url
        default: nil
        }
    }

    func resolved(with context: VariableContext?) -> EngageAction {
        switch self {
        case .openUrl(let value): .openUrl(interpolate(value, context: context))
        case .openDeeplink(let value): .openDeeplink(interpolate(value, context: context))
        case .copyToClipboard(let value): .copyToClipboard(interpolate(value, context: context))
        case .share(let value): .share(interpolate(value, context: context))
        case .customKV(let payload):
            .customKV(payload.reduce(into: [String: String]()) { result, entry in
                result[interpolate(entry.key, context: context)] = interpolate(entry.value, context: context)
            })
        default: self
        }
    }

}

struct EngageActionParser {
    func parse(_ onClick: [String: Any]?) -> [EngageAction] {
        guard let steps = onClick?["steps"] as? [[String: Any]] else { return [] }
        return steps.compactMap(parseStep)
    }

    private func parseStep(_ step: [String: Any]) -> EngageAction? {
        let data = step["data"] as? [String: Any] ?? [:]
        // `Action.*` is the dashboard wire format; unprefixed names keep previously stored
        // guide and nudge action payloads readable while campaigns migrate to canonical steps.
        switch step["type"] as? String ?? "" {
        case "Action.openUrl":
            guard let url = string(in: data, keys: ["url"]) ?? string(in: step, keys: ["url"]) else { return nil }
            let launchMode = string(in: data, keys: ["launchMode", "launch_mode"])
                ?? string(in: step, keys: ["launchMode", "launch_mode"])
                ?? ""
            return ["externalApplication", "inAppBrowser"].contains(launchMode)
                ? .openUrl(url) : .openDeeplink(url)
        case "open_url":
            return (string(in: data, keys: ["url"]) ?? string(in: step, keys: ["url"]))
                .map(EngageAction.openUrl)
        case "deep_link":
            return (string(in: data, keys: ["url"]) ?? string(in: step, keys: ["url"]))
                .map(EngageAction.openDeeplink)
        case "Action.copyToClipBoard", "copy":
            return (text(from: data) ?? text(from: step)).map(EngageAction.copyToClipboard)
        case "Action.share", "share":
            return (text(from: data) ?? text(from: step)).map(EngageAction.share)
        case "Action.hideBottomSheet", "Action.dismissDialog", "Action.dismiss", "dismiss", "hide": return .dismiss
        case "Action.next", "next": return .next
        case "Action.previous", "previous", "back", "prev": return .previous
        case "Action.requestReview", "requestReview", "request_review": return .requestReview
        case "Action.customKV":
            guard let raw = data["payload"] as? [String: Any] else { return nil }
            return customKV(from: raw)
        default: return nil
        }
    }

    private func customKV(from raw: [String: Any]) -> EngageAction? {
        let payload = raw.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String { result[entry.key] = value }
        }
        return payload.isEmpty ? nil : .customKV(payload)
    }

    private func text(from data: [String: Any]) -> String? {
        string(in: data, keys: ["message", "text", "value"])
    }

    private func string(in object: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
    }
}
