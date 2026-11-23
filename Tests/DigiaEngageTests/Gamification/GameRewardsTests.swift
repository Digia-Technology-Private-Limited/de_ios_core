import Foundation
import Testing

@testable import DigiaEngage

/// `getRewards` parsing: soonest-expiry-first sorting, the playable flag and
/// defensive decoding. Each test names the production line that fails it.
@Suite("Game rewards", .tags(.unit, .game))
struct GameRewardsTests {
    private func chance(
        _ id: String, campaignId: String = "bills", expires: String? = nil, playable: Bool? = nil
    ) -> [String: Any] {
        var raw: [String: Any] = ["chanceId": id, "campaignId": campaignId]
        if let expires { raw["expiresAt"] = expires }
        if let playable { raw["playable"] = playable }
        return raw
    }

    private func response(chances: [[String: Any]]) -> [String: Any] {
        ["chances": chances, "campaigns": []]
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
            "widget": ["tapAction": "soonestChance", "content": ["kind": "mystery"]],
            "extra": true,
        ])

        #expect(parsed.chances.map(\.chanceId) == ["a"])
        #expect(parsed.chances.first?.playable == true)
        #expect(parsed.chances.first?.expiresAt == nil)
        #expect(
            GameRewardsResponse.widgetContent(chances: [], widget: parsed.widget) == .hidden)
    }
}
