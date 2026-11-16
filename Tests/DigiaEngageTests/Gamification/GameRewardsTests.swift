import Foundation
import Testing

@testable import DigiaEngage

/// S6 `getRewards` parsing: soonest-expiry-first sorting, the playable flag,
/// widget content selection and widget tap resolution. Each test names the
/// production line that fails it.
@Suite("Game rewards", .tags(.unit, .game))
struct GameRewardsTests {
    private func chance(
        _ id: String, expires: String? = nil, playable: Bool? = nil, format: String? = "spinWheel"
    ) -> [String: Any] {
        var raw: [String: Any] = ["chanceId": id, "campaignKey": "bills"]
        if let expires { raw["expiresAt"] = expires }
        if let playable { raw["playable"] = playable }
        if let format { raw["format"] = format }
        return raw
    }

    private func response(
        chances: [[String: Any]] = [],
        active: [[String: Any]] = [],
        used: [[String: Any]] = [],
        expired: [[String: Any]] = [],
        widget: [String: Any]? = nil,
        emptyMessage: String? = nil
    ) -> [String: Any] {
        var raw: [String: Any] = [
            "chances": chances,
            "campaigns": [],
            "rewards": ["active": active, "used": used, "expired": expired],
        ]
        if let widget { raw["widget"] = widget }
        if let emptyMessage { raw["emptyMessage"] = emptyMessage }
        return raw
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
            ["campaignKey": "bills"],
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
            "rewards": ["active": [["title": "Cash", "bogus": 1]]],
            "widget": ["chancesCount": "many"],
            "emptyMessage": 7,
            "extra": true,
        ])

        #expect(parsed.chances.map(\.chanceId) == ["a"])
        #expect(parsed.chances.first?.playable == true)
        #expect(parsed.chances.first?.expiresAt == nil)
        #expect(parsed.active.first?.title == "Cash")
        #expect(parsed.widget?.chancesCount == nil)
        #expect(parsed.emptyMessage == nil)
    }

    @Test("a reward with nothing to show is dropped")
    func emptyRewardDropped() {
        let parsed = GameRewardsResponse.fromJson(response(
            active: [["title": "Cash"], ["id": "ghost"]]))

        #expect(parsed.active.map(\.title) == ["Cash"])
        #expect(!parsed.isEmpty)
    }

    @Test("an empty response reports empty and keeps the message")
    func emptyResponse() {
        let parsed = GameRewardsResponse.fromJson(response(emptyMessage: "Play to earn!"))

        #expect(parsed.isEmpty)
        #expect(parsed.emptyMessage == "Play to earn!")
    }

    @Test("widget prefers chances, then the latest reward, else empty or hidden")
    func widgetSelection() {
        let waiting = GameRewardChance.fromJson(chance("c1"))!
        let reward = GameReward.fromJson(["title": "Cash"])!

        // Guards the selection order in widgetContent.
        if case .chances(let count, _, _) = GameRewardsResponse.widgetContent(
            chances: [waiting], active: [reward], widget: nil)
        {
            #expect(count == 1)
        } else {
            Issue.record("chances should win")
        }

        if case .reward(let latest) = GameRewardsResponse.widgetContent(
            chances: [], active: [reward], widget: nil)
        {
            #expect(latest == reward)
        } else {
            Issue.record("latest reward should show")
        }

        #expect(
            GameRewardsResponse.widgetContent(chances: [], active: [], widget: nil) == .hidden)
        #expect(
            GameRewardsResponse.widgetContent(
                chances: [], active: [],
                widget: GameRewardsWidget.fromJson(["message": "Come back soon"]))
            == .empty(message: "Come back soon"))
    }

    @Test("widget tap opens an explicit waiting chance, else soonest, else the page")
    func widgetTap() {
        let first = GameRewardChance.fromJson(chance("c1"))!
        let second = GameRewardChance.fromJson(chance("c2"))!
        let chances = [first, second]

        // Guards the tap resolution in widgetTap.
        #expect(
            GameRewardsResponse.widgetTap(
                chances: chances,
                widget: GameRewardsWidget.fromJson(
                    ["tapAction": ["type": "openChance", "chanceId": "c2"]]))
            == .openChance(chanceId: "c2"))
        #expect(
            GameRewardsResponse.widgetTap(chances: chances, widget: nil)
            == .openChance(chanceId: "c1"))
        #expect(
            GameRewardsResponse.widgetTap(
                chances: chances,
                widget: GameRewardsWidget.fromJson(["tapAction": ["type": "openRewards"]]))
            == .openPage)
        #expect(GameRewardsResponse.widgetTap(chances: [], widget: nil) == .openPage)
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

    @Test("an explicitly hidden widget stays hidden, even with chances waiting")
    func hiddenWidgetStaysHidden() {
        let waiting = GameRewardChance.fromJson(chance("c1"))!

        // Guards the hidden check in widgetContent: holdout users see nothing.
        #expect(
            GameRewardsResponse.widgetContent(
                chances: [waiting], active: [],
                widget: GameRewardsWidget.fromJson(["hidden": true]))
            == .hidden)
    }

    @Test("a rewardsPage tap verb opens the page, and tap prefers a playable chance")
    func widgetTapPageVerbAndPlayable() {
        let waiting = GameRewardChance.fromJson(chance("c1"))!

        // Guards the tap verb list in fromJson: the backend's open-page verb.
        #expect(
            GameRewardsResponse.widgetTap(
                chances: [waiting],
                widget: GameRewardsWidget.fromJson(["tapAction": "rewardsPage"]))
            == .openPage)

        let unplayable = GameRewardChance.fromJson(chance("c1", playable: false))!
        let playable = GameRewardChance.fromJson(chance("c2", playable: true))!

        // Guards the playable preference in widgetTap: an unavailable soonest
        // chance never opens ahead of a playable one.
        #expect(
            GameRewardsResponse.widgetTap(chances: [unplayable, playable], widget: nil)
            == .openChance(chanceId: "c2"))
    }

    @Test("a chance carrying the server campaign id still keys its campaign")
    func chanceAcceptsCampaignId() {
        let parsed = GameRewardChance.fromJson(["chanceId": "c1", "campaignId": "srv-9"])

        // Guards the campaignId fallback: the rewards game lookup needs a key.
        #expect(parsed?.campaignKey == "srv-9")
    }
}
