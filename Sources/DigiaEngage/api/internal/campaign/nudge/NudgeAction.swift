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
        case .customKV: "custom_kv"
        case .dismiss: "dismiss"
        case .next: "next"
        case .previous: "previous"
        case .requestReview: "request_review"
        }
    }

    func resolved(with context: VariableContext?) -> EngageAction {
        switch self {
        case .openUrl(let value): .openUrl(interpolate(value, context: context))
        case .openDeeplink(let value): .openDeeplink(interpolate(value, context: context))
        case .copyToClipboard(let value): .copyToClipboard(interpolate(value, context: context))
        case .share(let value): .share(interpolate(value, context: context))
        case .customKV(let payload):
            .customKV(payload.mapValues { interpolate($0, context: context) })
        default: self
        }
    }

    var hostAction: HostAction? {
        switch self {
        case .openUrl(let url): .openURL(url)
        case .openDeeplink(let url): .deepLink(url)
        case .customKV(let payload): .customKV(payload)
        default: nil
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
        switch step["type"] as? String ?? "" {
        case "Action.openUrl":
            guard let url = data["url"] as? String, !url.isEmpty else { return nil }
            return ["externalApplication", "inAppBrowser"].contains(data["launchMode"] as? String ?? "")
                ? .openUrl(url) : .openDeeplink(url)
        case "Action.copyToClipBoard": return text(from: data).map(EngageAction.copyToClipboard)
        case "Action.share": return text(from: data).map(EngageAction.share)
        case "Action.hideBottomSheet", "Action.dismissDialog", "Action.dismiss": return .dismiss
        case "Action.next": return .next
        case "Action.previous": return .previous
        case "Action.requestReview": return .requestReview
        case "Action.customKV":
            guard let raw = data["payload"] as? [String: Any] else { return nil }
            let payload = raw.reduce(into: [String: String]()) { result, entry in
                if let value = entry.value as? String { result[entry.key] = value }
            }
            return payload.isEmpty ? nil : .customKV(payload)
        default: return nil
        }
    }

    private func text(from data: [String: Any]) -> String? {
        for key in ["message", "text", "value"] {
            if let value = data[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

typealias NudgeAction = EngageAction
typealias NudgeActionParser = EngageActionParser
