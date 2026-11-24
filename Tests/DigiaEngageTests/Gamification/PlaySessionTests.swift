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

        func state(campaignKey: String, testInvocationId: String?, chanceId: String?) async -> ChanceStateResult {
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

    // Guards the admission gate (`admit`): a game on screen blocks a direct trigger.
    @Test("a game already showing fails busy without calling")
    func busyGame() async {
        let source = FakeSource(.granted(granted(show: true)))

        let decision = await session(source).request(playRequest(isGameBusy: { true }))

        #expect(decision == .drop(reason: PlayDropReason.busy, denyReason: nil))
        #expect(source.grantCalls == 0)
    }

    /// Holds the first grant open until the test releases it; later grants
    /// answer at once. The lock guards state shared with the source's executor.
    private final class GatedSource: GameOutcomeSource, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var pending: CheckedContinuation<GrantChanceResult, Never>?

        var grantCalls: Int { lock.withLock { calls } }
        var isHolding: Bool { lock.withLock { pending != nil } }

        func grantChance(_ request: GrantChanceRequest) async -> GrantChanceResult {
            let first = lock.withLock { calls += 1; return calls == 1 }
            guard first else { return .granted(GrantedChance(chanceId: "ch-3", expiresAt: nil, show: true)) }
            return await withCheckedContinuation { cont in lock.withLock { pending = cont } }
        }

        func release(_ result: GrantChanceResult) {
            let cont = lock.withLock { () -> CheckedContinuation<GrantChanceResult, Never>? in
                defer { pending = nil }
                return pending
            }
            cont?.resume(returning: result)
        }

        func state(campaignKey: String, testInvocationId: String?, chanceId: String?) async -> ChanceStateResult { .none }

        func getRewards() async -> Result<GameRewardsResponse, GameOutcomeError> {
            .failure(.transport("unused"))
        }
    }

    // Guards the admission gate (`admit`): two direct triggers for different
    // campaigns must not both ask while the first grant is in flight, and the
    // guard is released afterwards (its reset in `defer`).
    @Test("a second direct trigger fails busy while the first grant is in flight")
    func directInFlight() async {
        let source = GatedSource()
        let session = PlaySession(source: source, identity: { PlaySessionTests.identity })
        func direct(_ key: String) -> PlayRequest {
            PlayRequest(campaignKey: key, triggerId: "t-\(key)", testInvocationId: nil, direct: true, isGameBusy: { false })
        }

        let first = Task { await session.request(direct("spin")) }
        for _ in 0..<1000 where !source.isHolding { await Task.yield() }
        let second = await session.request(direct("scratch"))
        source.release(.granted(GrantedChance(chanceId: "ch-1", expiresAt: nil, show: true)))
        _ = await first.value
        let third = await session.request(direct("chest"))

        #expect(second == .drop(reason: PlayDropReason.busy, denyReason: nil))
        #expect(third == .open(GrantedChance(chanceId: "ch-3", expiresAt: nil, show: true)))
        #expect(source.grantCalls == 2)
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
            (.failure(.transport("timed out", timedOut: true)),
             .drop(reason: PlayDropReason.timeout, denyReason: nil)),
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

    // Guards admission through `request`: a live-test direct trigger replaces
    // the visible game instead of dropping busy, while an entry trigger still
    // asks. Fails if `admit` stops exempting the test send.
    @Test("a live-test direct opens over a visible game; an entry still asks")
    func liveTestDirectExempt() async {
        let live = playRequest(direct: true, testInvocationId: "inv-1", isGameBusy: { true })
        let liveDecision = await session(FakeSource(.granted(granted(show: true)))).request(live)
        #expect(liveDecision == .open(granted(show: true)))

        let entry = playRequest(direct: false, isGameBusy: { true })
        let entryDecision = await session(FakeSource(.granted(granted(show: false)))).request(entry)
        #expect(entryDecision == .showEntry(granted(show: false)))
    }

    // Fails if a played chance keeps the floater (the `.played` case in
    // `decideAfterClose`), or a failed call dismisses it (the `.failed` arm).
    @Test("a played chance hides the entry after close; a failed call keeps it")
    func playedHidesEntry() {
        #expect(PlaySession.decideAfterClose(.played(chanceId: "ch-1")) == .hide)
        #expect(PlaySession.decideAfterClose(.failed(.transport("offline"))) == .keep(nil))
    }

    // Fails if the busy gate stops exempting a live test, or exempts a live
    // campaign: the `gameVisible && !isLiveTest` line in `decideTap`.
    @Test("a live-test tap opens over a visible game; a live tap stays busy")
    func liveTestTapReplacesVisibleGame() {
        let chance = granted(show: true)
        #expect(PlaySession.decideTap(gameVisible: true, isLiveTest: true, chance: chance) == .open(chance))
        #expect(
            PlaySession.decideTap(gameVisible: true, isLiveTest: false, chance: chance)
                == .fail(reason: PlayDropReason.busy))
    }

    // Fails if a refusal reads as the wrong reason: the `switch` in
    // `PlaySession.dropReason(forDenyReason:)`. Only the two real caps may
    // read `frequency_capped`; an unknown or missing reason never does.
    @Test("a refused chance drops with the reason the backend gave")
    func refusedChanceDropsWithTheBackendReason() {
        let expected: [(String, DropReason)] = [
            ("capReached", .frequencyCapped),
            ("alreadyPlayed", .frequencyCapped),
            ("notVerified", .userNotVerified),
            ("notLive", .campaignNotLive),
            ("notInAudience", .notInAudience),
            ("budgetUsed", .budgetExhausted),
            ("chanceExpired", .chanceExpired),
            ("somethingNew", .notEligible),
        ]
        for (denyReason, reason) in expected {
            #expect(PlaySession.dropReason(forDenyReason: denyReason) == reason)
        }
        #expect(PlaySession.dropReason(forDenyReason: nil) == .notEligible)
    }
}
