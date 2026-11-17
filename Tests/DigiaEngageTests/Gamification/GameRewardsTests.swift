import Foundation
import Testing

@testable import DigiaEngage

/// `getRewards` parsing: soonest-expiry-first sorting, the playable flag,
/// grant and widget content selection, and widget tap resolution. Each test
/// names the production line that fails it.
@Suite("Game rewards", .tags(.unit, .game))
struct GameRewardsTests {
    private func chance(
        _ id: String, campaignId: String = "bills", format: String? = "spinWheel",
        title: String? = nil, expires: String? = nil, playable: Bool? = nil
    ) -> [String: Any] {
        var raw: [String: Any] = ["chanceId": id, "campaignId": campaignId]
        if let format { raw["format"] = format }
        if let title { raw["rewardsPageTitle"] = title }
        if let expires { raw["expiresAt"] = expires }
        if let playable { raw["playable"] = playable }
        return raw
    }

    private func grant(
        _ id: String, name: String? = "Cash", type: String = "coupon",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var raw: [String: Any] = ["grantId": id, "type": type]
        if let name { raw["name"] = name }
        return raw.merging(extra) { current, _ in current }
    }

    private func response(
        chances: [[String: Any]] = [],
        active: [[String: Any]] = [],
        used: [[String: Any]] = [],
        expiredGrants: [[String: Any]] = [],
        expiredChances: [[String: Any]] = [],
        widget: [String: Any]? = nil,
        emptyMessage: String? = nil
    ) -> [String: Any] {
        var raw: [String: Any] = [
            "chances": chances,
            "campaigns": [],
            "rewards": [
                "active": active, "used": used,
                "expired": ["grants": expiredGrants, "chances": expiredChances],
            ],
        ]
        if let widget { raw["widget"] = widget }
        if let emptyMessage { raw["emptyMessage"] = emptyMessage }
        return raw
    }

    private func chancesWidget(count: Int, tapAction: String = "soonestChance") -> [String: Any] {
        [
            "layoutKey": NSNull(), "tapAction": tapAction,
            "content": [
                "kind": "chances", "count": count, "formats": ["spinWheel"],
                "soonestExpiresAt": "2026-11-17T10:00:00Z",
            ],
        ]
    }

    @Test("chances sort soonest-expiry-first, missing expiry last")
    func chancesSortSoonestFirst() {
        let parsed = GameRewardsResponse.fromJson(response(chances: [
            chance("late", expires: "2026-12-01T00:00:00Z"),
            chance("none"),
            chance("soon", expires: "2026-11-17T00:00:00Z"),
        ]))

        // Guards the sort in fromJson: the widget opens chances.first.
        #expect(parsed.chances.map(\.chanceId) == ["soon", "late", "none"])
    }

    @Test("a chance without a chance id is dropped, the rest survive")
    func missingChanceIdDropped() {
        let parsed = GameRewardsResponse.fromJson(response(chances: [
            ["campaignId": "bills"],
            chance("kept"),
        ]))

        #expect(parsed.chances.map(\.chanceId) == ["kept"])
    }

    @Test("playable defaults to true, explicit false is kept")
    func playableDefault() {
        let parsed = GameRewardsResponse.fromJson(response(chances: [
            chance("a"),
            chance("b", playable: false),
        ]))

        // Guards the default in fromJson: only explicit false is unavailable.
        #expect(parsed.chances.map(\.playable) == [true, false])
    }

    @Test("unknown or mistyped fields degrade, never drop the list")
    func defensiveDecode() {
        let parsed = GameRewardsResponse.fromJson([
            "chances": [
                ["chanceId": "a", "playable": "yes", "expiresAt": "not-a-date",
                 "unknown": ["nested": true]],
            ],
            "rewards": [
                "active": [["grantId": "g1", "type": "mystery", "bogus": 1]],
                "expired": ["grants": [["name": "Ghost"]], "chances": [["bogus": 1]]],
            ],
            "widget": ["tapAction": "soonestChance", "content": ["kind": "mystery"]],
            "emptyMessage": 7,
            "extra": true,
        ])

        #expect(parsed.chances.map(\.chanceId) == ["a"])
        #expect(parsed.chances.first?.playable == true)
        #expect(parsed.chances.first?.expiresAt == nil)
        #expect(parsed.active.isEmpty)
        #expect(parsed.expiredGrants.isEmpty)
        #expect(parsed.expiredChances.isEmpty)
        #expect(
            GameRewardsResponse.widgetContent(chances: [], widget: parsed.widget) == .hidden)
        #expect(parsed.emptyMessage == nil)
    }

    @Test("a grant with an unknown type or nothing to show is dropped")
    func emptyGrantDropped() {
        let parsed = GameRewardsResponse.fromJson(response(
            active: [grant("kept"), grant("typed", name: "X", type: "mystery"), ["name": "Ghost"]]))

        #expect(parsed.active.map(\.grantId) == ["kept"])
        #expect(!parsed.isEmpty)
    }

    @Test("an empty response reports empty and keeps the message")
    func emptyResponse() {
        let parsed = GameRewardsResponse.fromJson(response(emptyMessage: "Play to earn!"))

        #expect(parsed.isEmpty)
        #expect(parsed.emptyMessage == "Play to earn!")
    }

    @Test("expired grants and expired chances parse into the expired section")
    func expiredSection() {
        let parsed = GameRewardsResponse.fromJson(response(
            expiredGrants: [grant("g1")],
            expiredChances: [[
                "chanceId": "c1", "campaignId": "bills",
                "rewardsPageTitle": "Diwali wheel", "expiredAt": "2026-11-10T00:00:00Z",
            ]]))

        #expect(parsed.expiredGrants.map(\.grantId) == ["g1"])
        #expect(parsed.expiredChances.map(\.chanceId) == ["c1"])
        #expect(parsed.expiredChances.first?.rewardsPageTitle == "Diwali wheel")
        #expect(!parsed.isEmpty)
    }

    @Test("widget reads the backend content kinds, else hides")
    func widgetSelection() {
        let chances = [GameRewardChance.fromJson(chance("c1"))!]
        let latest = GameReward.fromJson(grant("g1"))!

        // Guards the kind read in widgetContent.
        #expect(
            GameRewardsResponse.widgetContent(
                chances: chances,
                widget: GameRewardsWidget.fromJson(chancesWidget(count: 2)))
                == .chances(
                    count: 2, formats: ["spinWheel"],
                    soonestExpiry: GameRewardChance.expiry("2026-11-17T10:00:00Z")))
        #expect(
            GameRewardsResponse.widgetContent(
                chances: [], widget: GameRewardsWidget.fromJson([
                    "layoutKey": NSNull(), "tapAction": "rewardsPage",
                    "content": ["kind": "reward", "grant": grant("g1")],
                ])) == .reward(latest))
        #expect(
            GameRewardsResponse.widgetContent(
                chances: [], widget: GameRewardsWidget.fromJson([
                    "layoutKey": NSNull(), "tapAction": "rewardsPage",
                    "content": ["kind": "empty", "message": "Come back soon"],
                ])) == .empty(message: "Come back soon"))
        #expect(GameRewardsResponse.widgetContent(chances: [], widget: nil) == .hidden)
    }

    @Test("widget tap follows tapAction, preferring a playable chance")
    func widgetTap() {
        let waiting = GameRewardChance.fromJson(chance("c1"))!

        // Guards the tap resolution in widgetTap.
        #expect(
            GameRewardsResponse.widgetTap(
                chances: [waiting],
                widget: GameRewardsWidget.fromJson(chancesWidget(count: 1)))
            == .openChance(chanceId: "c1"))
        #expect(
            GameRewardsResponse.widgetTap(
                chances: [waiting],
                widget: GameRewardsWidget.fromJson(
                    chancesWidget(count: 1, tapAction: "rewardsPage")))
            == .openPage)
        #expect(GameRewardsResponse.widgetTap(chances: [], widget: nil) == .openPage)

        let unplayable = GameRewardChance.fromJson(chance("c1", playable: false))!
        let playable = GameRewardChance.fromJson(chance("c2", playable: true))!

        // Guards the playable preference in widgetTap: an unavailable soonest
        // chance never opens ahead of a playable one.
        #expect(
            GameRewardsResponse.widgetTap(
                chances: [unplayable, playable],
                widget: GameRewardsWidget.fromJson(chancesWidget(count: 2)))
            == .openChance(chanceId: "c2"))
    }

    @Test("expiry reads ISO-8601 and epoch forms")
    func expiryForms() {
        #expect(GameRewardChance.expiry("2026-11-17T10:00:00Z") != nil)
        #expect(GameRewardChance.expiry("2026-11-17T10:00:00.123Z") != nil)
        #expect(GameRewardChance.expiry(1_764_000_000) != nil)
        #expect(GameRewardChance.expiry(1_764_000_000_000) != nil)
        #expect(GameRewardChance.expiry("tomorrow") == nil)
        #expect(GameRewardChance.expiry(true) == nil)
    }

    @Test("a chance keeps its page title and campaign id")
    func chanceKeepsIdentity() {
        let parsed = GameRewardChance.fromJson(
            chance("c1", campaignId: "srv-9", title: "Diwali wheel"))

        #expect(parsed?.campaignId == "srv-9")
        #expect(parsed?.rewardsPageTitle == "Diwali wheel")
    }
}
