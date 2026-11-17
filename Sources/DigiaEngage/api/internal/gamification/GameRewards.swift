import Foundation

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
    let format: String?
    let rewardsPageTitle: String?
    let expiresAt: Date?
    /// A chance with `playable: false` shows as unavailable, never hidden.
    let playable: Bool

    static func fromJson(_ raw: [String: Any]) -> GameRewardChance? {
        guard let chanceId = raw.nonBlankString("chanceId") else { return nil }
        return GameRewardChance(
            chanceId: chanceId,
            campaignId: raw.nonBlankString("campaignId") ?? "",
            format: raw.nonBlankString("format"),
            rewardsPageTitle: raw.nonBlankString("rewardsPageTitle"),
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

/// One grant from `getRewards`, in any of the active/used/expired-grants
/// lists. The backend's flat grant shape: the copy plus its id, no nested
/// objects. An unknown `type` skips the grant; a grant with nothing to show
/// is dropped at parse time so the lists never render an empty row.
struct GameReward: Equatable, Sendable {
    let grantId: String
    let expiresAt: Date?
    let name: String?
    let type: GameRewardType
    let imageUrl: String?
    let offeredBy: String?
    let partnerName: String?
    let bannerImageUrl: String?
    let headline: String?
    let description: String?
    let terms: String?
    let referenceKey: String?
    let value: GameRewardValue?
    let howToUse: String?
    /// The grant CTA's label and deep link. A missing label renders as
    /// "Use now".
    let ctaLabel: String?
    let ctaDeepLink: String?
    let code: String?
    let amount: Double?
    let unit: String?
    let displayText: String?

    static func fromJson(_ raw: [String: Any]) -> GameReward? {
        guard let grantId = raw.nonBlankString("grantId"),
              let typeRaw = raw.nonBlankString("type"),
              let type = GameRewardType(rawValue: typeRaw)
        else { return nil }
        let cta = raw.object("cta") ?? [:]
        let reward = GameReward(
            grantId: grantId,
            expiresAt: GameRewardChance.expiry(raw["expiresAt"]),
            name: raw.nonBlankString("name"),
            type: type,
            imageUrl: raw.nonBlankString("imageUrl"),
            offeredBy: raw.nonBlankString("offeredBy"),
            partnerName: raw.nonBlankString("partnerName"),
            bannerImageUrl: raw.nonBlankString("bannerImageUrl"),
            headline: raw.nonBlankString("headline"),
            description: raw.nonBlankString("description"),
            terms: raw.nonBlankString("terms"),
            referenceKey: raw.nonBlankString("referenceKey"),
            value: (raw.object("value")).flatMap(GameRewardValue.fromJson),
            howToUse: raw.nonBlankString("howToUse"),
            ctaLabel: cta.nonBlankString("label"),
            ctaDeepLink: cta.nonBlankString("deepLink"),
            code: raw.nonBlankString("code"),
            amount: Self.number(raw["amount"]),
            unit: raw.nonBlankString("unit"),
            displayText: raw.nonBlankString("displayText")
        )
        guard reward.name != nil || reward.code != nil || reward.description != nil
            || reward.howToUse != nil || reward.headline != nil || reward.displayText != nil
            || reward.imageUrl != nil || reward.ctaDeepLink != nil
        else { return nil }
        return reward
    }

    /// A JSON number as a Double. Non-numbers and non-finite values read as nil.
    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        return double.isFinite ? double : nil
    }
}

/// A grant's reward type. Anything else skips the grant, never a crash.
enum GameRewardType: String, Equatable, Sendable {
    case coupon
    case currency
    case perk
}

/// A grant's value, in integer minor units with an ISO currency code.
struct GameRewardValue: Equatable, Sendable {
    let amountMinor: Int
    let currency: String

    static func fromJson(_ raw: [String: Any]) -> GameRewardValue? {
        guard let amount = raw["amountMinor"] as? NSNumber,
              CFGetTypeID(amount) != CFBooleanGetTypeID(),
              let currency = raw.nonBlankString("currency")
        else { return nil }
        return GameRewardValue(amountMinor: amount.intValue, currency: currency)
    }
}

/// One spent chance from `getRewards`: it had a game, but it expired
/// unplayed. Renders in the expired section under its page title.
struct GameExpiredChance: Equatable, Sendable {
    let chanceId: String
    let campaignId: String
    let rewardsPageTitle: String?
    let expiredAt: Date?

    static func fromJson(_ raw: [String: Any]) -> GameExpiredChance? {
        guard let chanceId = raw.nonBlankString("chanceId") else { return nil }
        return GameExpiredChance(
            chanceId: chanceId,
            campaignId: raw.nonBlankString("campaignId") ?? "",
            rewardsPageTitle: raw.nonBlankString("rewardsPageTitle"),
            expiredAt: GameRewardChance.expiry(raw["expiredAt"])
        )
    }
}

/// The `widget` object of `getRewards`: what the `digia_rewards_widget` slot
/// shows, and what its tap does. A null widget — including for holdout users —
/// degrades to the same hidden slot as an unknown content kind.
struct GameRewardsWidget: Equatable, Sendable {
    let layoutKey: String?
    /// `soonestChance` opens the soonest playable chance, `rewardsPage`
    /// opens the page. Unknown values open the page.
    let tapAction: String?
    let content: GameRewardsWidgetContentData?

    static func fromJson(_ raw: [String: Any]) -> GameRewardsWidget {
        GameRewardsWidget(
            layoutKey: raw["layoutKey"] as? String,
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
        case chances(count: Int, formats: [String], soonestExpiresAt: Date?)
        case reward(grant: GameReward)
        case empty(message: String)
    }

    static func fromJson(_ raw: [String: Any]) -> GameRewardsWidgetContentData? {
        switch raw.nonBlankString("kind") {
        case "chances":
            guard let count = raw["count"] as? NSNumber,
                  CFGetTypeID(count) != CFBooleanGetTypeID()
            else { return nil }
            return GameRewardsWidgetContentData(kind: .chances(
                count: count.intValue,
                formats: raw.stringArray("formats"),
                soonestExpiresAt: GameRewardChance.expiry(raw["soonestExpiresAt"])
            ))
        case "reward":
            guard let grant = raw.object("grant").flatMap(GameReward.fromJson) else { return nil }
            return GameRewardsWidgetContentData(kind: .reward(grant: grant))
        case "empty":
            guard let message = raw.nonBlankString("message") else { return nil }
            return GameRewardsWidgetContentData(kind: .empty(message: message))
        default:
            return nil
        }
    }
}

/// What the rewards widget slot shows, read off the backend's widget content.
enum GameRewardsWidgetContent: Equatable, Sendable {
    case hidden
    case chances(count: Int, formats: [String], soonestExpiry: Date?)
    case reward(GameReward)
    case empty(message: String?)
}

/// What a widget tap does: open one chance the way an entry does, or open the
/// rewards page. Resolved by
/// ``GameRewardsResponse/widgetTap(chances:widget:)``.
enum GameRewardsTap: Equatable, Sendable {
    case openChance(chanceId: String)
    case openPage
}

/// The `getRewards` response: `{ chances, campaigns, rewards: { active, used,
/// expired: { grants, chances } }, widget, emptyMessage }`. A chance whose
/// campaign is paused or ended is not in the campaign bundle; its campaign
/// comes in `campaigns` in the same shape as the bundle.
struct GameRewardsResponse {
    let chances: [GameRewardChance]
    /// Raw campaign JSONs for paused/ended campaigns, same shape as the
    /// bundle. Parsed by `SDKInstance` when the response is stored.
    let campaigns: [[String: Any]]
    let active: [GameReward]
    let used: [GameReward]
    let expiredGrants: [GameReward]
    let expiredChances: [GameExpiredChance]
    let widget: GameRewardsWidget?
    let emptyMessage: String?

    var isEmpty: Bool {
        chances.isEmpty && active.isEmpty && used.isEmpty
            && expiredGrants.isEmpty && expiredChances.isEmpty
    }

    static func fromJson(_ raw: [String: Any]) -> GameRewardsResponse {
        let chances =
            raw.objectArray("chances")
            .compactMap(GameRewardChance.fromJson)
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let rewards = raw.object("rewards") ?? [:]
        let expired = rewards.object("expired") ?? [:]
        return GameRewardsResponse(
            chances: chances,
            campaigns: raw.objectArray("campaigns"),
            active: rewards.objectArray("active").compactMap(GameReward.fromJson),
            used: rewards.objectArray("used").compactMap(GameReward.fromJson),
            expiredGrants: expired.objectArray("grants").compactMap(GameReward.fromJson),
            expiredChances: expired.objectArray("chances").compactMap(GameExpiredChance.fromJson),
            widget: raw.object("widget").map(GameRewardsWidget.fromJson),
            emptyMessage: raw.nonBlankString("emptyMessage")
        )
    }

    /// Reads the widget content: chances waiting (count, formats, soonest
    /// expiry), the grant, or the empty message — hidden when the backend
    /// hides it or sends anything unknown.
    static func widgetContent(
        chances: [GameRewardChance], widget: GameRewardsWidget?
    ) -> GameRewardsWidgetContent {
        guard let content = widget?.content else { return .hidden }
        switch content.kind {
        case .chances(let count, let formats, let soonest):
            return .chances(count: count, formats: formats, soonestExpiry: soonest)
        case .reward(let grant):
            return .reward(grant)
        case .empty(let message):
            return .empty(message: message)
        }
    }

    /// Follows the widget's tap action: `soonestChance` opens the soonest
    /// playable waiting chance — or the page, when none waits — and anything
    /// else opens the page.
    static func widgetTap(
        chances: [GameRewardChance], widget: GameRewardsWidget?
    ) -> GameRewardsTap {
        if widget?.tapAction == "soonestChance" {
            if let soonest = chances.first(where: \.playable) ?? chances.first {
                return .openChance(chanceId: soonest.chanceId)
            }
        }
        return .openPage
    }
}
