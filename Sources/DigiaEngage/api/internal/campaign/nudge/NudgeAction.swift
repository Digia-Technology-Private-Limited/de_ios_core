import Foundation

enum NudgeAction: Equatable {
    case openUrl(String)
    case openDeeplink(String)
    case copyToClipboard(String)
    case share(String)
    case dismiss
    case requestReview
}

struct NudgeActionParser {
    func parse(_ onClick: [String: Any]?) -> [NudgeAction] {
        guard let onClick,
              let steps = onClick["steps"] as? [[String: Any]] else { return [] }
        return steps.compactMap { parseStep($0) }
    }

    private func parseStep(_ step: [String: Any]) -> NudgeAction? {
        let data = step["data"] as? [String: Any] ?? [:]
        switch step["type"] as? String ?? "" {
        case "Action.openUrl":
            guard let url = data["url"] as? String, !url.isEmpty else { return nil }
            return data["launchMode"] as? String == "externalApplication"
                ? .openUrl(url) : .openDeeplink(url)
        case "Action.copyToClipBoard":
            return text(from: data).map { .copyToClipboard($0) }
        case "Action.share":
            return text(from: data).map { .share($0) }
        case "Action.hideBottomSheet", "Action.dismissDialog":
            return .dismiss
        case "Action.requestReview":
            return .requestReview
        default:
            return nil
        }
    }

    /// The action's text payload — canonical `message`, with `text`/`value` fallbacks.
    private func text(from data: [String: Any]) -> String? {
        for key in ["message", "text", "value"] {
            if let value = data[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
