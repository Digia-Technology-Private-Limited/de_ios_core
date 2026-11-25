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

    private func widget(tapAction: String?, content: [String: Any]) -> GameRewardsWidget {
        var raw: [String: Any] = ["content": content]
        if let tapAction { raw["tapAction"] = tapAction }
        return GameRewardsWidget.fromJson(raw)
    }

    @Test("an unknown tapAction opens the page, a missing one opens the chance")
    func tapActionRules() {
        let chances = [
            GameRewardChance(chanceId: "locked", campaignId: "c", expiresAt: nil, playable: false),
            GameRewardChance(chanceId: "open", campaignId: "c", expiresAt: nil, playable: true),
        ]
        let content: [String: Any] = ["kind": "chances", "count": 2]

        // Guards the tapAction check in widgetTap.
        #expect(GameRewardsResponse.widgetTap(
            chances: chances, widget: widget(tapAction: "somethingNew", content: content)) == .openPage)
        #expect(GameRewardsResponse.widgetTap(
            chances: chances, widget: widget(tapAction: nil, content: content))
            == .openChance(chanceId: "open"))
        #expect(GameRewardsResponse.widgetTap(
            chances: Array(chances.prefix(1)),
            widget: widget(tapAction: "soonestChance", content: content))
            == .openChance(chanceId: "locked"))
        #expect(GameRewardsResponse.widgetTap(
            chances: [], widget: widget(tapAction: "soonestChance", content: content)) == .openPage)
    }

    @Test("unusable widget content hides the widget")
    func hideRules() {
        let hidden: [[String: Any]] = [
            ["kind": "chances", "count": 0],
            ["kind": "reward", "grant": ["name": "  "]],
            ["kind": "empty", "message": " "],
        ]
        for content in hidden {
            // Guards the count, name and message checks in the content parser.
            #expect(
                GameRewardsResponse.widgetContent(
                    chances: [], widget: widget(tapAction: nil, content: content)) == .hidden)
        }
    }

    @Test("a reward's second line is code, then display text, then amount and unit")
    func rewardDetail() {
        func detail(_ grant: [String: Any]) -> String? { GameReward.fromJson(grant)?.detail }
        #expect(detail(["name": "n", "code": "SAVE10", "displayText": "d", "amount": "5", "unit": "pts",
                        "referenceKey": "r"]) == "SAVE10")
        #expect(detail(["name": "n", "displayText": "d", "referenceKey": "r"]) == "d")
        #expect(detail(["name": "n", "amount": "5", "unit": "pts", "referenceKey": "r"]) == "5 pts")
        #expect(detail(["name": "n", "referenceKey": "r"]) == nil)
    }

    @Test("ends-in uses the largest whole unit and hides once past")
    func endsInUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(gameRewardsEndsIn(now.addingTimeInterval(2 * 86400 + 5), now: now) == "Ends in 2d")
        #expect(gameRewardsEndsIn(now.addingTimeInterval(5 * 3600 + 5), now: now) == "Ends in 5h")
        #expect(gameRewardsEndsIn(now.addingTimeInterval(12 * 60 + 5), now: now) == "Ends in 12m")
        #expect(gameRewardsEndsIn(now.addingTimeInterval(-1), now: now) == nil)
    }

    private func rewardsEnvelope(_ response: String) -> String {
        #"{"isSuccess":true,"data":{"response":\#(response)}} "#
            .trimmingCharacters(in: .whitespaces)
    }

    // Fails if `getRewards` stops hitting the gamification path or stops
    // reading the `{isSuccess, data:{response}}` envelope. Mirrors Android
    // `RewardsRepositoryTest:33`: the user rides the SDK identity (headers),
    // the body stays the empty object, and chances/campaigns/page parse.
    @Test("getRewards posts the path and parses the envelope")
    @MainActor
    func fetchPostsPathAndParsesEnvelope() async throws {
        let client = MockNetworkClient()
        let source = HttpGameOutcomeSource(networkClient: client)
        client.enqueueResponse(
            statusCode: 200,
            body: rewardsEnvelope(
                #"{"chances":[],"campaigns":[],"page":{"url":"https://rewards.digia.tech"}}"#))

        let result = await source.getRewards()

        guard case .success(let response) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(response.chances.isEmpty)
        #expect(response.pageUrl == "https://rewards.digia.tech")
        let sent = try #require(client.lastRequest)
        #expect(sent.url.absoluteString.hasSuffix("/api/v1/engage/sdk/gamification/getRewards"))
        let body = try #require(sent.body.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        // Identity travels in the headers, as on every call; the body stays
        // the empty object (Android posts the userId, iOS never does).
        #expect(body.isEmpty)
    }

    // Fails if a fetch without a user still calls: `refreshRewards` must drop
    // the stale response and return without a call. Mirrors Android
    // `RewardsRepositoryTest:51` (null/blank user → null with zero calls).
    @Test("refresh without a user makes no call and keeps no rewards")
    @MainActor
    func noUserMakesNoCall() async throws {
        let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
        let sdk = SDKInstance(
            defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() })
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
        let client = try #require(sdk.networkClient as? MockNetworkClient)
        client.reset()
        // No user set: identity is empty, so there is nothing to fetch for.
        sdk.setUserId("")
        sdk.gamification.refreshRewards()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Guards the user-id check in refreshRewards: no call, no stale.
        #expect(client.requestCount == 0)
        #expect(sdk.gamification.rewardsResponse == nil)
    }

    // Fails if transport, status or envelope faults stop mapping to the
    // classified failure. Mirrors Android `RewardsRepositoryTest:59`.
    @Test("getRewards maps failures to a classified failure")
    func fetchMapsFailures() async {
        let client = MockNetworkClient()
        let source = HttpGameOutcomeSource(networkClient: client)

        client.enqueueResponse(statusCode: 500, body: "{}")
        guard case .failure(let status) = await source.getRewards() else {
            Issue.record("expected a status failure")
            return
        }
        #expect(status.rewardsCode == "status")
        #expect(status.rewardsStatus == 500)

        client.reset()
        client.enqueueResponse(statusCode: 200, body: #"{"isSuccess":false,"data":{}}"#)
        guard case .failure(let invalid) = await source.getRewards() else {
            Issue.record("expected an invalid_response failure")
            return
        }
        #expect(invalid.rewardsCode == "invalid_response")
        #expect(invalid.rewardsStatus == nil)

        client.reset()
        client.simulateTransportError(URLError(.notConnectedToInternet))
        guard case .failure(let transport) = await source.getRewards() else {
            Issue.record("expected a transport failure")
            return
        }
        #expect(transport.rewardsCode == "network")
        #expect(transport.rewardsStatus == nil)

        client.reset()
        client.simulateTransportError(URLError(.timedOut))
        guard case .failure(let timeout) = await source.getRewards() else {
            Issue.record("expected a timeout failure")
            return
        }
        // Guards the timedOut flag: a timeout stays a timeout, never network.
        #expect(timeout.rewardsCode == "timeout")
    }
}
