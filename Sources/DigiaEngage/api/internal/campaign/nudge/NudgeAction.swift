import Foundation

enum NudgeAction {
    case openUrl(String)
    case openDeeplink(String)
    case dismiss
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
        case "Action.hideBottomSheet", "Action.dismissDialog":
            return .dismiss
        default:
            return nil
        }
    }
}
