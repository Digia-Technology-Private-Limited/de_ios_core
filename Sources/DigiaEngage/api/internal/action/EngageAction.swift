import Foundation

enum EngageAction: Equatable {
    case openUrl(String, presentation: String? = nil)
    case openDeeplink(String, fallbackUrl: String? = nil)
    case copyToClipboard(String)
    case share(String)
    case customKV([String: String])
    case dismiss
    case next
    case previous
    case requestReview
    /// Open a canvas story's viewer at this 0-based index.
    ///
    /// The escape hatch for a story campaign whose rail is switched off: with
    /// nothing on the card to tap, any element the author draws can open the
    /// stories instead. Handled by the canvas stage rather than the shared
    /// action runner — it is the only thing that knows which stories to open.
    case showStory(Int)

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
        case .showStory: "show_story"
        }
    }

    var analyticsURL: String? {
        switch self {
        case .openUrl(let url, _), .openDeeplink(let url, _): url
        default: nil
        }
    }

    var isLink: Bool {
        switch self {
        case .openUrl, .openDeeplink: true
        default: false
        }
    }

    func resolved(with context: VariableContext?) -> EngageAction {
        switch self {
        case .openUrl(let value, let presentation):
            .openUrl(interpolate(value, context: context), presentation: presentation)
        case .openDeeplink(let value, let fallbackUrl):
            .openDeeplink(
                interpolate(value, context: context),
                fallbackUrl: fallbackUrl.map { interpolate($0, context: context) }
            )
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
            if ["externalApplication", "inAppBrowser"].contains(launchMode) {
                return .openUrl(
                    url,
                    presentation: launchMode == "inAppBrowser" ? "in_app" : nil
                )
            }
            return .openDeeplink(
                url,
                fallbackUrl: string(in: data, keys: ["fallbackUrl", "fallback_url"])
                    ?? string(in: step, keys: ["fallbackUrl", "fallback_url"])
            )
        case "open_url":
            guard let url = string(in: data, keys: ["url"])
                ?? string(in: step, keys: ["url"])
            else { return nil }
            let launchMode = string(in: data, keys: ["launchMode", "launch_mode"])
                ?? string(in: step, keys: ["launchMode", "launch_mode"])
            let presentation = string(in: data, keys: ["presentation"])
                ?? string(in: step, keys: ["presentation"])
            return .openUrl(
                url,
                presentation: presentation == "in_app" || launchMode == "inAppBrowser"
                    ? "in_app"
                    : nil
            )
        case "deep_link":
            guard let url = string(in: data, keys: ["url"])
                ?? string(in: step, keys: ["url"])
            else { return nil }
            return .openDeeplink(
                url,
                fallbackUrl: string(in: data, keys: ["fallbackUrl", "fallback_url"])
                    ?? string(in: step, keys: ["fallbackUrl", "fallback_url"])
            )
        case "Action.copyToClipBoard", "copy":
            return (text(from: data) ?? text(from: step)).map(EngageAction.copyToClipboard)
        case "Action.share", "share":
            return (text(from: data) ?? text(from: step)).map(EngageAction.share)
        // `Action.hideInline` is an inline canvas closing itself: there is no
        // overlay to pop, so the host clears the slot for the session. Same
        // authored intent as the overlay spellings, so the same action.
        case "Action.hideBottomSheet", "Action.dismissDialog", "Action.hideInline",
             "Action.dismiss", "dismiss", "hide": return .dismiss
        case "Action.next", "next": return .next
        case "Action.previous", "previous", "back", "prev": return .previous
        case "Action.requestReview", "requestReview", "request_review": return .requestReview
        case "Action.showStory":
            let raw = data["index"] ?? step["index"]
            let index = (raw as? NSNumber)?.intValue ?? Int("\(raw ?? "")") ?? 0
            return .showStory(max(0, index))
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
