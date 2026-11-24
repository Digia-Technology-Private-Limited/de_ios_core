import Foundation

private let log = DigiaLogger()

extension DigiaEndpoints {
    static var gamificationGetRewards: String {
        "\(baseUrl)/api/v1/engage/sdk/gamification/getRewards"
    }
}

/// One unplayed chance from `getRewards`, in the backend's own keys. A chance
/// whose expiry is missing or unreadable sorts last; only a missing chance id
/// drops the entry.
struct GameRewardChance: Equatable, Sendable {
    let chanceId: String
    let campaignId: String
    let expiresAt: Date?
    /// A chance with `playable: false` shows as unavailable, never hidden.
    let playable: Bool

    static func fromJson(_ raw: [String: Any]) -> GameRewardChance? {
        guard let chanceId = raw.nonBlankString("chanceId") else { return nil }
        return GameRewardChance(
            chanceId: chanceId,
            campaignId: raw.nonBlankString("campaignId") ?? "",
            expiresAt: Self.expiry(raw["expiresAt"]),
            playable: Self.strictBool(raw["playable"]) ?? true
        )
    }

    /// An expiry as an ISO-8601 string or an epoch (seconds or milliseconds).
    /// Anything else reads as nil and sorts last — never a dropped chance.
    static func expiry(_ raw: Any?) -> Date? {
        if let string = raw as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string)
        }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }

    /// A strict boolean: JSON booleans bridge to `NSNumber`, and so does every
    /// number — only a real boolean counts. Nil when absent or not a boolean.
    static func strictBool(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// A string with something visible in it: whitespace-only reads as absent,
    /// so a blank name or message hides the widget instead of showing a gap.
    func visibleString(_ key: String) -> String? {
        guard let value = self[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}

/// The widget's latest reward: the two lines it shows from the backend's flat
/// grant shape. A missing or blank `name` drops the grant, so the widget hides.
struct GameReward: Equatable, Sendable {
    let name: String
    /// Secondary line: `code`, else `displayText`, else `amount unit`. Never
    /// `referenceKey`.
    let detail: String?

    static func fromJson(_ raw: [String: Any]) -> GameReward? {
        guard let name = raw.visibleString("name") else { return nil }
        let amountUnit: String? = {
            guard let amount = raw.visibleString("amount"), let unit = raw.visibleString("unit")
            else { return nil }
            return "\(amount) \(unit)"
        }()
        return GameReward(
            name: name,
            detail: raw.visibleString("code") ?? raw.visibleString("displayText") ?? amountUnit)
    }
}

/// The `widget` object of `getRewards`: what the `digia_rewards_widget` slot
/// shows, and what its tap does. A null widget — including for holdout users —
/// degrades to the same hidden slot as an unknown content kind.
struct GameRewardsWidget: Equatable, Sendable {
    /// `soonestChance` opens the soonest playable chance, `rewardsPage`
    /// opens the page. Missing means `soonestChance`; unknown values open the page.
    let tapAction: String?
    let content: GameRewardsWidgetContentData?

    static func fromJson(_ raw: [String: Any]) -> GameRewardsWidget {
        GameRewardsWidget(
            tapAction: raw.nonBlankString("tapAction"),
            content: (raw.object("content")).flatMap(GameRewardsWidgetContentData.fromJson)
        )
    }
}

/// The widget's content, in the backend's kinds. Anything else reads as nil
/// and the slot hides.
struct GameRewardsWidgetContentData: Equatable, Sendable {
    let kind: Kind

    enum Kind: Equatable, Sendable {
        case chances(count: Int, soonestExpiresAt: Date?)
        case reward(grant: GameReward)
        case empty(message: String)
    }

    static func fromJson(_ raw: [String: Any]) -> GameRewardsWidgetContentData? {
        switch raw.nonBlankString("kind") {
        case "chances":
            guard let count = raw["count"] as? NSNumber,
                  CFGetTypeID(count) != CFBooleanGetTypeID(),
                  count.intValue > 0
            else { return hidden("chances count missing or not positive") }
            return GameRewardsWidgetContentData(kind: .chances(
                count: count.intValue,
                soonestExpiresAt: GameRewardChance.expiry(raw["soonestExpiresAt"])
            ))
        case "reward":
            guard let grant = raw.object("grant").flatMap(GameReward.fromJson)
            else { return hidden("reward grant missing or unnamed") }
            return GameRewardsWidgetContentData(kind: .reward(grant: grant))
        case "empty":
            guard let message = raw.visibleString("message")
            else { return hidden("empty message blank") }
            return GameRewardsWidgetContentData(kind: .empty(message: message))
        default:
            return hidden("unknown widget kind")
        }
    }

    private static func hidden(_ reason: String) -> GameRewardsWidgetContentData? {
        log.w("Rewards widget hidden — \(reason)")
        return nil
    }
}

/// What the rewards widget slot shows, read off the backend's widget content.
enum GameRewardsWidgetContent: Equatable, Sendable {
    case hidden
    case chances(count: Int, soonestExpiry: Date?)
    case reward(GameReward)
    case empty(message: String)
}

/// What a widget tap does: open one chance the way an entry does, or open the
/// rewards page. Resolved by
/// ``GameRewardsResponse/widgetTap(chances:widget:)``.
enum GameRewardsTap: Equatable, Sendable {
    case openChance(chanceId: String)
    case openPage
}

/// The `getRewards` response fields the SDK reads: `{ chances, campaigns,
/// widget, page }`. A chance whose
/// campaign is paused or ended is not in the campaign bundle; its campaign
/// comes in `campaigns` in the same shape as the bundle.
struct GameRewardsResponse {
    let chances: [GameRewardChance]
    /// Raw campaign JSONs for paused/ended campaigns, same shape as the
    /// bundle. Parsed by `SDKInstance` when the response is stored.
    let campaigns: [[String: Any]]
    let widget: GameRewardsWidget?
    /// `page.url`: where the hosted rewards page lives for this environment.
    var pageUrl: String? = nil

    static func fromJson(_ raw: [String: Any]) -> GameRewardsResponse {
        let chances =
            raw.objectArray("chances")
            .compactMap(GameRewardChance.fromJson)
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return GameRewardsResponse(
            chances: chances,
            campaigns: raw.objectArray("campaigns"),
            widget: raw.object("widget").map(GameRewardsWidget.fromJson),
            pageUrl: raw.object("page")?.nonBlankString("url")
        )
    }

    /// Reads the widget content: chances waiting (count, soonest
    /// expiry), the grant, or the empty message — hidden when the backend
    /// hides it or sends anything unknown.
    static func widgetContent(
        chances: [GameRewardChance], widget: GameRewardsWidget?
    ) -> GameRewardsWidgetContent {
        guard let content = widget?.content else { return .hidden }
        switch content.kind {
        case .chances(let count, let soonest):
            return .chances(count: count, soonestExpiry: soonest)
        case .reward(let grant):
            return .reward(grant)
        case .empty(let message):
            return .empty(message: message)
        }
    }

    /// Follows the widget's tap action: a missing one or `soonestChance` opens
    /// the first playable waiting chance (else the first) — or the page, when
    /// none waits — and anything else, `rewardsPage` or unknown, opens the page.
    static func widgetTap(
        chances: [GameRewardChance], widget: GameRewardsWidget?
    ) -> GameRewardsTap {
        if widget?.tapAction == nil || widget?.tapAction == "soonestChance" {
            if let soonest = chances.first(where: \.playable) ?? chances.first {
                return .openChance(chanceId: soonest.chanceId)
            }
        }
        return .openPage
    }
}

/// "Ends in 3d" / "Ends in 5h" / "Ends in 12m": the largest whole unit, at
/// least a minute; nil when the expiry is unknown or already past.
func gameRewardsEndsIn(_ expiresAt: Date?, now: Date = Date()) -> String? {
    guard let expiresAt else { return nil }
    let seconds = Int(expiresAt.timeIntervalSince(now))
    guard seconds > 0 else { return nil }
    if seconds >= 86400 { return "Ends in \(seconds / 86400)d" }
    if seconds >= 3600 { return "Ends in \(seconds / 3600)h" }
    return "Ends in \(max(1, seconds / 60))m"
}
