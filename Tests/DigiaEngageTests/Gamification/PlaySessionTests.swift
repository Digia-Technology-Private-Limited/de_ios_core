import Foundation
import Testing

@testable import DigiaEngage

/// The play decisions: when a trigger may ask for a chance, and which decision
/// a granted, denied or failed grant maps to. Each test names the production
/// line it guards in `PlaySession.request`. Mirrors Android's `PlaySessionTest`.
@MainActor
@Suite("Play session", .tags(.unit, .gamification))
struct PlaySessionTests {
    /// Records what `PlaySession` sent and answers with a fixed grant. The
    /// tests run on the main actor, so the unchecked `Sendable` is safe.
    private final class FakeSource: GameOutcomeSource, @unchecked Sendable {
        var grant: GrantChanceResult
        var grantCalls = 0
        var lastRequest: GrantChanceRequest?

        init(_ grant: GrantChanceResult) { self.grant = grant }

        func grantChance(_ request: GrantChanceRequest) async -> GrantChanceResult {
            grantCalls += 1
            lastRequest = request
            return grant
        }

        func state(campaignKey: String, testInvocationId: String?) async -> ChanceStateResult {
            .none
        }

        func getRewards() async -> Result<GameRewardsResponse, GameOutcomeError> {
            .failure(.transport("unused"))
        }
    }

    private static let identity = PlayIdentity(userId: "u-123", userHash: nil, deviceId: "d-1")

    private func session(
        _ source: FakeSource, identity: PlayIdentity? = PlaySessionTests.identity
    ) -> PlaySession {
        PlaySession(source: source, identity: { identity })
    }

    private func playRequest(
        direct: Bool = true,
        triggerId: String = "msg-9",
        testInvocationId: String? = nil,
        isGameBusy: @escaping () -> Bool = { false }
    ) -> PlayRequest {
        PlayRequest(
            campaignKey: "bill_pay_spin",
            triggerId: triggerId,
            testInvocationId: testInvocationId,
            direct: direct,
            isGameBusy: isGameBusy
        )
    }

    private func granted(show: Bool) -> GrantedChance {
        GrantedChance(chanceId: "ch-1", expiresAt: nil, show: show)
    }

    // Guards the `isGameBusy` early return: a game on screen blocks a direct trigger.
    @Test("a game already showing fails busy without calling")
    func busyGame() async {
        let source = FakeSource(.granted(granted(show: true)))

        let decision = await session(source).request(playRequest(isGameBusy: { true }))

        #expect(decision == .drop(reason: PlayDropReason.busy, denyReason: nil))
        #expect(source.grantCalls == 0)
    }

    // Guards the blank-trigger early return: the SDK never invents a triggerId.
    @Test("a trigger without an id fails missing config without calling")
    func blankTrigger() async {
        let source = FakeSource(.granted(granted(show: true)))

        let decision = await session(source).request(playRequest(triggerId: "  "))

        #expect(decision == .drop(reason: PlayDropReason.missingConfig, denyReason: nil))
        #expect(source.grantCalls == 0)
    }

    // Guards the no-user early return: a missing user id never reaches `grantChance`.
    @Test("a missing user id fails missing config without calling")
    func missingUser() async {
        let source = FakeSource(.granted(granted(show: true)))

        let decision = await session(source, identity: nil).request(playRequest())

        #expect(decision == .drop(reason: PlayDropReason.missingConfig, denyReason: nil))
        #expect(source.grantCalls == 0)
    }

    // Guards the `granted` branch: `granted && show` on a direct trigger opens.
    @Test("a granted shown chance opens")
    func grantedShown() async {
        let chance = granted(show: true)
        let source = FakeSource(.granted(chance))

        let decision = await session(source).request(playRequest(testInvocationId: "inv-1"))

        #expect(decision == .open(chance))
        #expect(source.lastRequest?.triggerId == "msg-9")
        #expect(source.lastRequest?.showNow == true)
        #expect(source.lastRequest?.testInvocationId == "inv-1")
    }

    // Guards the `show` gate on a direct open: `granted && !show` drops `not_shown`.
    @Test("a direct held chance drops not_shown")
    func grantedHeld() async {
        let source = FakeSource(.granted(granted(show: false)))

        let decision = await session(source).request(playRequest())

        #expect(decision == .drop(reason: PlayDropReason.notShown, denyReason: nil))
    }

    // Guards that `show` never gates an entry: a non-direct grant renders even without `show`.
    @Test("a granted chance renders its entry when not direct, even without show")
    func shownEntry() async {
        let chance = granted(show: false)
        let source = FakeSource(.granted(chance))

        let decision = await session(source).request(playRequest(direct: false))

        #expect(decision == .showEntry(chance))
    }

    // Guards the `denied` and `failure` branches of the grant switch.
    @Test("a denial or failure maps to fail")
    func denialOrFailure() async {
        let cases: [(GrantChanceResult, PlayDecision)] = [
            (.denied(reason: "capReached"),
             .drop(reason: PlayDropReason.denied, denyReason: "capReached")),
            (.failure(.transport("offline")),
             .drop(reason: PlayDropReason.network, denyReason: nil)),
            (.failure(.httpStatus(500)),
             .drop(reason: PlayDropReason.network, denyReason: nil)),
            (.failure(.invalidResponse("bad")),
             .drop(reason: PlayDropReason.invalidResponse, denyReason: nil)),
        ]
        for (result, expected) in cases {
            let decision = await session(FakeSource(result)).request(playRequest())

            #expect(decision == expected)
        }
    }

    // Guards the identity line: the user id and hash ride to `grantChance`.
    @Test("the user identity is passed to grantChance")
    func identityPassed() async {
        let source = FakeSource(.granted(granted(show: true)))
        let identity = PlayIdentity(userId: "u-123", userHash: "h-1", deviceId: "d-1")

        _ = await session(source, identity: identity).request(playRequest())

        #expect(source.lastRequest?.userId == "u-123")
        #expect(source.lastRequest?.userHash == "h-1")
    }
}
