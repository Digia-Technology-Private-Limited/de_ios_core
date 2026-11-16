import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

extension DigiaEndpoints {
    static var gamificationGetRewards: String {
        "\(baseUrl)/api/v1/engage/sdk/gamification/getRewards"
    }
}

/// One unplayed chance from `getRewards`: the same grant the server would hand
/// an entry tap, already in hand. Parsed defensively — unknown or missing
/// fields degrade (a missing expiry sorts last, a missing format shows the
/// campaign title), and only a missing chance id drops the entry.
struct GameRewardChance: Equatable, Sendable {
    let chanceId: String
    let campaignKey: String
    let format: String?
    let expiresAt: Date?
    /// A chance with `playable: false` shows as unavailable, never hidden.
    let playable: Bool

    static func fromJson(_ raw: [String: Any]) -> GameRewardChance? {
        guard let chanceId = raw.nonBlankString("chanceId")
            ?? raw.nonBlankString("chance_id") ?? raw.nonBlankString("id")
        else { return nil }
        return GameRewardChance(
            chanceId: chanceId,
            campaignKey: raw.nonBlankString("campaignKey")
                ?? raw.nonBlankString("campaign_key") ?? "",
            format: raw.nonBlankString("format"),
            expiresAt: Self.expiry(
                raw["expiresAt"] ?? raw["expiry"] ?? raw["expiryAt"] ?? raw["expires_at"]),
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

/// One reward from `getRewards`, in any of the active/used/expired lists.
/// Every field is optional; a reward with nothing to show is dropped at
/// parse time so the lists never render an empty row.
struct GameReward: Equatable, Sendable {
    let rewardId: String?
    let campaignKey: String?
    let title: String?
    let code: String?
    let instructions: String?
    let imageUrl: String?
    /// The reward's CTA deep link, opened through the host action executor.
    let deepLink: String?
    let ctaLabel: String?

    static func fromJson(_ raw: [String: Any]) -> GameReward? {
        let cta = raw.object("cta") ?? [:]
        let reward = GameReward(
            rewardId: raw.nonBlankString("rewardId") ?? raw.nonBlankString("id"),
            campaignKey: raw.nonBlankString("campaignKey") ?? raw.nonBlankString("campaign_key"),
            title: raw.nonBlankString("title") ?? raw.nonBlankString("name"),
            code: raw.nonBlankString("code") ?? raw.nonBlankString("couponCode"),
            instructions: raw.nonBlankString("instructions")
                ?? raw.nonBlankString("howToUse") ?? raw.nonBlankString("description"),
            imageUrl: raw.nonBlankString("imageUrl") ?? raw.nonBlankString("image"),
            deepLink: cta.nonBlankString("deepLink") ?? cta.nonBlankString("deeplink")
                ?? raw.nonBlankString("deepLink") ?? raw.nonBlankString("url"),
            ctaLabel: cta.nonBlankString("label") ?? cta.nonBlankString("text")
                ?? raw.nonBlankString("ctaLabel")
        )
        guard reward.title != nil || reward.code != nil || reward.instructions != nil
            || reward.deepLink != nil || reward.imageUrl != nil
        else { return nil }
        return reward
    }
}

/// The `widget` object of `getRewards`: what the `digia_rewards_widget` slot
/// shows, and what its tap does. Every field is optional — the selection below
/// falls back to the response's own chances and rewards.
struct GameRewardsWidget: Equatable, Sendable {
    let chancesCount: Int?
    let formats: [String]
    let soonestExpiry: Date?
    let latestReward: GameReward?
    /// The backend already hides holdout users; an explicit hide degrades to
    /// the same empty slot.
    let isHidden: Bool
    let message: String?
    /// An explicit tap target: a chance id to open, or an open-the-page verb.
    let tapChanceId: String?
    let tapOpenPage: Bool

    static func fromJson(_ raw: [String: Any]) -> GameRewardsWidget {
        let tap = raw.object("tapAction") ?? raw.object("tap") ?? [:]
        let tapType = tap.nonBlankString("type") ?? tap.nonBlankString("action")
            ?? (raw["tapAction"] as? String) ?? (raw["tap"] as? String)
        let tapChanceId = tap.nonBlankString("chanceId") ?? tap.nonBlankString("chance_id")
            ?? tap.nonBlankString("chance")
        return GameRewardsWidget(
            chancesCount: (raw["count"] as? NSNumber).map(\.intValue)
                ?? (raw["chancesCount"] as? NSNumber).map(\.intValue)
                ?? (raw["chances"] as? NSNumber).map(\.intValue),
            formats: raw.stringArray("formats"),
            soonestExpiry: GameRewardChance.expiry(
                raw["soonestExpiry"] ?? raw["expiresAt"] ?? raw["expiry"]),
            latestReward: (raw.object("reward") ?? raw.object("latestReward")).flatMap(GameReward.fromJson),
            isHidden: GameRewardChance.strictBool(raw["hidden"] ?? raw["isHidden"]) ?? false,
            message: raw.nonBlankString("message") ?? raw.nonBlankString("emptyMessage")
                ?? raw.nonBlankString("text"),
            tapChanceId: tapChanceId,
            tapOpenPage: tapType.map {
                ["openRewards", "open_rewards", "rewards", "openPage", "open_page"].contains($0)
            } ?? false
        )
    }
}

/// What the rewards widget slot shows. Selected by
/// ``GameRewardsResponse/widgetContent(chances:active:widget:)``: chances
/// waiting first, else the latest unused reward, else the empty state.
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
/// expired }, widget, emptyMessage }`. A chance whose campaign is paused or
/// ended is not in the campaign bundle; its campaign comes in `campaigns` in
/// the same shape as the bundle.
struct GameRewardsResponse {
    let chances: [GameRewardChance]
    /// Raw campaign JSONs for paused/ended campaigns, same shape as the
    /// bundle. Parsed by `SDKInstance` when the response is stored.
    let campaigns: [[String: Any]]
    let active: [GameReward]
    let used: [GameReward]
    let expired: [GameReward]
    let widget: GameRewardsWidget?
    let emptyMessage: String?

    var isEmpty: Bool {
        chances.isEmpty && active.isEmpty && used.isEmpty && expired.isEmpty
    }

    static func fromJson(_ raw: [String: Any]) -> GameRewardsResponse {
        let chances =
            raw.objectArray("chances")
            .compactMap(GameRewardChance.fromJson)
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let rewards = raw.object("rewards") ?? [:]
        return GameRewardsResponse(
            chances: chances,
            campaigns: raw.objectArray("campaigns"),
            active: rewards.objectArray("active").compactMap(GameReward.fromJson),
            used: rewards.objectArray("used").compactMap(GameReward.fromJson),
            expired: rewards.objectArray("expired").compactMap(GameReward.fromJson),
            widget: raw.object("widget").map(GameRewardsWidget.fromJson),
            emptyMessage: raw.nonBlankString("emptyMessage") ?? raw.nonBlankString("empty_message")
        )
    }

    /// Picks the widget content: chances waiting (count, formats, soonest
    /// expiry) first, else the latest unused reward, else the empty state —
    /// hidden, or the project's message. Unknown or missing fields degrade to
    /// the response's own data, never to a crash.
    static func widgetContent(
        chances: [GameRewardChance], active: [GameReward], widget: GameRewardsWidget?
    ) -> GameRewardsWidgetContent {
        if !chances.isEmpty {
            let formats =
                widget.map(\.formats).flatMap { $0.isEmpty ? nil : $0 }
                ?? Array(Set(chances.compactMap(\.format))).sorted()
            return .chances(
                count: widget?.chancesCount ?? chances.count,
                formats: formats,
                soonestExpiry: widget?.soonestExpiry
                    ?? chances.lazy.compactMap(\.expiresAt).first
            )
        }
        if let reward = widget?.latestReward ?? active.first {
            return .reward(reward)
        }
        if let message = widget?.message, !message.isEmpty {
            return .empty(message: message)
        }
        return .hidden
    }

    /// Follows the widget's tap action: an explicit chance that is still
    /// waiting opens it, an explicit open-page verb opens the page, and
    /// otherwise the soonest chance opens — or the page, when none waits.
    static func widgetTap(
        chances: [GameRewardChance], widget: GameRewardsWidget?
    ) -> GameRewardsTap {
        if let chanceId = widget?.tapChanceId,
           chances.contains(where: { $0.chanceId == chanceId })
        {
            return .openChance(chanceId: chanceId)
        }
        if widget?.tapOpenPage == true { return .openPage }
        if let soonest = chances.first { return .openChance(chanceId: soonest.chanceId) }
        return .openPage
    }
}
