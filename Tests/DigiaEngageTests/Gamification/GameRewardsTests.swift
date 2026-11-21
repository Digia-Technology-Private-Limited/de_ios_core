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
}
