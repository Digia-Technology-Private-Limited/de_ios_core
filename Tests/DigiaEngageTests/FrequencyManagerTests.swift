import Foundation
import Testing
@testable import DigiaEngage

/// Golden matrix for native (nudge + survey) frequency capping. Mirrors the RN
/// `frequencyEvaluator.test.ts` and the Android `FrequencyManagerTest.kt` exactly
/// — `now` and `sessionId` are injected for determinism.
@Suite("FrequencyManager", .serialized)
struct FrequencyManagerTests {

    private let hour: Int64 = 3_600_000
    private let day: Int64 = 86_400_000

    private func win(_ count: Int, _ window: String) -> FrequencyWindow {
        FrequencyWindow(count: count, window: window)
    }

    // One show attempt: at `now`, under `sessionId`; `complete` records a stop after.
    private struct Attempt {
        let now: Int64
        var sessionId: String = "s1"
        var complete: Bool = false
    }

    // Drive a policy through attempts, threading state the way the wiring does:
    // evaluate → if allowed, recordShow.
    private func run(_ policy: FrequencyPolicy, _ attempts: [Attempt]) -> [Bool] {
        var state: FrequencyState?
        var allowed: [Bool] = []
        for a in attempts {
            let res = FrequencyEvaluator.evaluate(policy, state, a.now, a.sessionId)
            allowed.append(res.allow)
            if res.allow { state = FrequencyEvaluator.recordShow(policy, state, a.now, a.sessionId) }
            if a.complete { state = FrequencyEvaluator.recordStop(state, a.now) }
        }
        return allowed
    }

    @Test("1 — no-constraint policy is treated as uncapped")
    func noConstraint() {
        #expect(!FrequencyPolicy().hasConstraint)
        #expect(FrequencyPolicy(maxTotal: 1).hasConstraint)
    }

    @Test("2 — maxTotal 3 allows three then blocks")
    func maxTotal() {
        let p = FrequencyPolicy(maxTotal: 3)
        #expect(run(p, [Attempt(now: 0), Attempt(now: hour), Attempt(now: 2 * hour), Attempt(now: 3 * hour)])
            == [true, true, true, false])
    }

    @Test("3 — session window same session blocks second")
    func sessionSame() {
        let p = FrequencyPolicy(maxPerWindow: win(1, "session"))
        #expect(run(p, [Attempt(now: 0, sessionId: "s1"), Attempt(now: hour, sessionId: "s1")])
            == [true, false])
    }

    @Test("4 — session window rotated session allows both")
    func sessionRotated() {
        let p = FrequencyPolicy(maxPerWindow: win(1, "session"))
        #expect(run(p, [Attempt(now: 0, sessionId: "s1"), Attempt(now: hour, sessionId: "s2")])
            == [true, true])
    }

    @Test("5 — two per day blocks third within 24h")
    func twoPerDay() {
        let p = FrequencyPolicy(maxPerWindow: win(2, "day"))
        #expect(run(p, [Attempt(now: 0), Attempt(now: hour), Attempt(now: 2 * hour)])
            == [true, true, false])
    }

    @Test("6 — one per day rolls over after 25h")
    func dayRollover() {
        let p = FrequencyPolicy(maxPerWindow: win(1, "day"))
        #expect(run(p, [Attempt(now: 0), Attempt(now: 25 * hour)]) == [true, true])
    }

    @Test("7 — weekly and monthly roll over after their window")
    func weekMonth() {
        let week = FrequencyPolicy(maxPerWindow: win(1, "week"))
        #expect(run(week, [Attempt(now: 0), Attempt(now: 8 * day)]) == [true, true])
        #expect(run(week, [Attempt(now: 0), Attempt(now: 6 * day)]) == [true, false])
        let month = FrequencyPolicy(maxPerWindow: win(1, "month"))
        #expect(run(month, [Attempt(now: 0), Attempt(now: 31 * day)]) == [true, true])
        #expect(run(month, [Attempt(now: 0), Attempt(now: 29 * day)]) == [true, false])
    }

    @Test("8 — stopOn experienceCompleted blocks forever after completion")
    func stopOn() {
        let p = FrequencyPolicy(stopOn: "experienceCompleted")
        let allowed = run(p, [
            Attempt(now: 0, sessionId: "s1", complete: true),
            Attempt(now: hour, sessionId: "s1"),
            Attempt(now: 2 * day, sessionId: "s2"),
        ])
        #expect(allowed == [true, false, false])
    }

    @Test("9 — maxTotal plus per-day: per-day wins same day")
    func combined() {
        let p = FrequencyPolicy(maxTotal: 5, maxPerWindow: win(1, "day"))
        #expect(run(p, [Attempt(now: 0), Attempt(now: hour)]) == [true, false])
    }

    @Test("10 — maxTotal ignores session rotation")
    func maxTotalIgnoresSession() {
        let p = FrequencyPolicy(maxTotal: 2)
        #expect(run(p, [
            Attempt(now: 0, sessionId: "s1"),
            Attempt(now: hour, sessionId: "s2"),
            Attempt(now: 2 * hour, sessionId: "s3"),
        ]) == [true, true, false])
    }

    @Test("11 — session window cold start allows both")
    func coldStart() {
        let p = FrequencyPolicy(maxPerWindow: win(1, "session"))
        #expect(run(p, [Attempt(now: 0, sessionId: "cold-1"), Attempt(now: day, sessionId: "cold-2")])
            == [true, true])
    }

    @Test("12 — blocked attempt does not advance state")
    func blockedNoAdvance() {
        let p = FrequencyPolicy(maxTotal: 1)
        var state: FrequencyState?
        #expect(FrequencyEvaluator.evaluate(p, state, 0, "s1").allow)
        state = FrequencyEvaluator.recordShow(p, state, 0, "s1")
        #expect(state?.total == 1)
        #expect(!FrequencyEvaluator.evaluate(p, state, hour, "s1").allow)
        #expect(state?.total == 1)
    }

    @Test("recordShow re-anchors time window only on rollover")
    func reanchor() {
        let p = FrequencyPolicy(maxPerWindow: win(5, "day"))
        var s = FrequencyEvaluator.recordShow(p, nil, 1000, "s1")
        #expect(s == FrequencyState(total: 1, windowCount: 1, windowAnchorAt: 1000))
        s = FrequencyEvaluator.recordShow(p, s, 1000 + hour, "s1")
        #expect(s.total == 2 && s.windowCount == 2 && s.windowAnchorAt == 1000)
        s = FrequencyEvaluator.recordShow(p, s, 1000 + 25 * hour, "s1")
        #expect(s.total == 3 && s.windowCount == 1 && s.windowAnchorAt == 1000 + 25 * hour)
    }

    @Test("recordStop is idempotent")
    func recordStopIdempotent() {
        var s = FrequencyEvaluator.recordStop(nil, 500)
        #expect(s.stoppedAt == 500)
        s = FrequencyEvaluator.recordStop(s, 900)
        #expect(s.stoppedAt == 500)
    }

    // ── Persistence (FrequencyManager + isolated UserDefaults) ─────────────────

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "digia.freq.test.\(UUID().uuidString)")!
    }

    @Test("manager persists state across reloads and caps")
    func persistence() {
        let defaults = makeDefaults()
        var now: Int64 = 0
        var session = "s1"
        let policy = FrequencyPolicy(maxPerWindow: win(1, "session"))
        let mgr = FrequencyManager(defaults: defaults, sessionIdProvider: { session }, clock: { now })

        #expect(mgr.isAllowed(campaignKey: "camp", policy: policy))
        mgr.recordShow("camp", policy)
        now += hour
        #expect(!mgr.isAllowed(campaignKey: "camp", policy: policy)) // same session → capped

        // A fresh manager over the same store must see the persisted state.
        let mgr2 = FrequencyManager(defaults: defaults, sessionIdProvider: { session }, clock: { now })
        #expect(!mgr2.isAllowed(campaignKey: "camp", policy: policy))

        session = "s2" // rotate session → window resets
        #expect(mgr2.isAllowed(campaignKey: "camp", policy: policy))
    }

    @Test("manager recordCompleted stops only for experienceCompleted policies")
    func recordCompletedGate() {
        let defaults = makeDefaults()
        let mgr = FrequencyManager(defaults: defaults, sessionIdProvider: { "s1" }, clock: { 0 })

        // No stopOn → recordCompleted is a no-op.
        mgr.recordCompleted("a", FrequencyPolicy(maxTotal: 5))
        #expect(defaults.string(forKey: "\(FrequencyManager.keyPrefix)a") == nil)

        let stopPolicy = FrequencyPolicy(stopOn: "experienceCompleted")
        mgr.recordCompleted("b", stopPolicy)
        #expect(!mgr.isAllowed(campaignKey: "b", policy: stopPolicy))
    }

    @Test("fromJson reads camelCase and rejects empty / snake_case")
    func parse() {
        #expect(FrequencyPolicy.fromJson(nil) == nil)
        #expect(FrequencyPolicy.fromJson([:]) == nil)
        let p = FrequencyPolicy.fromJson([
            "maxTotal": 3,
            "maxPerWindow": ["count": 2, "window": "day"],
            "stopOn": "experienceCompleted",
        ])
        #expect(p?.maxTotal == 3)
        #expect(p?.maxPerWindow == FrequencyWindow(count: 2, window: "day"))
        #expect(p?.stopOn == "experienceCompleted")
        // Old snake_case payload has no recognised keys → uncapped (nil).
        #expect(FrequencyPolicy.fromJson(["max_total": 3, "stop_on": "click"]) == nil)
    }
}
