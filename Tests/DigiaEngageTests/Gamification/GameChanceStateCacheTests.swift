import Foundation
import Testing

@testable import DigiaEngage

/// The init `chanceState` contract
/// (ai_docs/gamification/eng/sdk/init-chance-state-contract.md): the SDK
/// stores only `playable` and `played` answers (only they carry a `chanceId`)
/// and sends the cached answer only for the same `chanceId`. Each test uses a
/// unique campaign key because the cache is in memory with no clear hook.
/// Mirrors Android `ChanceStateCacheTest` 1:1 against `GameChanceStateCache`.
@Suite("Game chance state cache", .serialized, .tags(.unit, .game))
struct GameChanceStateCacheTests {
    private func response(_ pairs: [(String, Any)]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: pairs)
    }

    private func envelope(_ response: [String: Any], isSuccess: Bool = true) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "isSuccess": isSuccess,
            "data": ["response": response],
        ])
        return String(data: data, encoding: .utf8)!
    }

    // Fails if `record` stops storing a playable answer: the state gate.
    @Test("record playable then lookup hits for same chanceId")
    func playableHit() {
        let key = "chance-cache-playable-hit-ios"
        GameChanceStateCache.shared.record(
            campaignKey: key,
            response: response([
                ("state", "playable"), ("chanceId", "ch-1"),
                ("expiresAt", "2026-11-24T00:00:00Z"),
            ]))

        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-1") != nil)
    }

    // Fails if `record` stops storing a played answer: the state gate.
    @Test("record played then lookup hits for same chanceId")
    func playedHit() {
        let key = "chance-cache-played-hit-ios"
        GameChanceStateCache.shared.record(
            campaignKey: key,
            response: response([
                ("state", "played"), ("chanceId", "ch-2"),
                ("result", ["rank": 1]),
            ]))

        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-2") != nil)
    }

    // Fails if `record` stores an expired answer: the state gate.
    @Test("record expired is ignored")
    func expiredIgnored() {
        let key = "chance-cache-expired-ignored-ios"
        GameChanceStateCache.shared.record(
            campaignKey: key, response: response([("state", "expired"), ("chanceId", "ch-3")]))

        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-3") == nil)
    }

    // Fails if `record` stores a none answer: the state gate.
    @Test("record none is ignored")
    func noneIgnored() {
        let key = "chance-cache-none-ignored-ios"
        GameChanceStateCache.shared.record(
            campaignKey: key, response: response([("state", "none"), ("chanceId", "ch-4")]))

        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-4") == nil)
    }

    // Fails if `record` stores a refused answer: the refused guard.
    @Test("record refused is ignored")
    func refusedIgnored() {
        let key = "chance-cache-refused-ignored-ios"
        GameChanceStateCache.shared.record(
            campaignKey: key,
            response: response([
                ("state", "playable"), ("chanceId", "ch-5"), ("refused", true),
            ]))

        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-5") == nil)
    }

    // Fails if `record` stores a played answer without a chanceId: the
    // blank-chanceId guard.
    @Test("record played without chanceId is ignored")
    func missingChanceIdIgnored() {
        let key = "chance-cache-no-chance-id-ios"
        GameChanceStateCache.shared.record(
            campaignKey: key, response: response([("state", "played")]))

        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-6") == nil)
    }

    // Fails if `record` stores an answer with a missing state: the state gate.
    @Test("record answer without state is ignored")
    func missingStateIgnored() {
        let key = "chance-cache-no-state-ios"
        GameChanceStateCache.shared.record(
            campaignKey: key, response: response([("chanceId", "ch-7")]))

        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-7") == nil)
    }

    // Fails if `lookup` returns a cached answer for a different chance: the
    // chanceId match.
    @Test("lookup with different chanceId returns nil")
    func mismatchReturnsNil() {
        let key = "chance-cache-mismatch-ios"
        GameChanceStateCache.shared.record(
            campaignKey: key,
            response: response([("state", "playable"), ("chanceId", "ch-8")]))

        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-other") == nil)
    }

    // Fails if the envelope path stores a non-playable answer: the state gate
    // via `record`, driven through `state` which unwraps
    // `{isSuccess, data:{response}}` exactly like `recordEnvelope`.
    @Test("envelope with expired state is ignored")
    func envelopeExpiredIgnored() async {
        let key = "chance-cache-envelope-expired-ios"
        let client = MockNetworkClient()
        let source = HttpGameOutcomeSource(networkClient: client)
        client.enqueueResponse(
            statusCode: 200,
            body: envelope(["state": "expired", "chanceId": "ch-9"]))

        _ = await source.state(campaignKey: key, testInvocationId: nil, chanceId: nil)
        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-9") == nil)
    }

    // Fails if the envelope path stops storing a playable answer: the
    // delegation to `record` through `state`.
    @Test("envelope with playable state records")
    func envelopePlayableRecords() async {
        let key = "chance-cache-envelope-playable-ios"
        let client = MockNetworkClient()
        let source = HttpGameOutcomeSource(networkClient: client)
        client.enqueueResponse(
            statusCode: 200,
            body: envelope(["state": "playable", "chanceId": "ch-10"]))

        _ = await source.state(campaignKey: key, testInvocationId: nil, chanceId: nil)
        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-10") != nil)
    }

    // Fails if the envelope path stores a failed envelope: the isSuccess guard
    // in the unwrap, before `record` ever runs.
    @Test("envelope without success is ignored")
    func envelopeFailedIgnored() async {
        let key = "chance-cache-envelope-failed-ios"
        let client = MockNetworkClient()
        let source = HttpGameOutcomeSource(networkClient: client)
        client.enqueueResponse(
            statusCode: 200,
            body: envelope(["state": "playable", "chanceId": "ch-11"], isSuccess: false))

        _ = await source.state(campaignKey: key, testInvocationId: nil, chanceId: nil)
        #expect(GameChanceStateCache.shared.lookup(campaignKey: key, chanceId: "ch-11") == nil)
    }
}
