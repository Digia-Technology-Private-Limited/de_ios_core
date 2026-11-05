import Foundation
import Testing
@testable import DigiaEngage

/// Collects every record, in order.
private final class RecordSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []

    var records: [TimelineRecord] { lock.withLock { stored } }

    func accepts(_ record: TimelineRecord) -> Bool { true }

    func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
}

/// The drawer the engine reads, with no SDK behind it.
@MainActor
private final class Facts: DecisionFacts {
    var ready = true
    var campaigns: [CampaignModel] = []
    private var index = TriggerIndex([])

    var attributes: [String: Any] = [:]
    var device: [String: Any] = [:]
    var currentScreen = ""
    var slots: [String: String] = [:]

    /// Campaigns whose frequency check blocks them.
    var capped2: Set<String> = []

    /// Real frequency state, wired the way `EngineFacts` wires it: the check
    /// and the show recording both go through the real `FrequencyManager`.
    /// Nil keeps the `capped2` stub above.
    var frequency: FrequencyManager?

    @discardableResult
    func add(_ campaign: CampaignModel) -> Facts {
        campaigns.append(campaign)
        index = TriggerIndex(campaigns)
        return self
    }

    /// Swaps the catalog, as a new bundle does. Nil empties it.
    func replace(_ campaign: CampaignModel?) {
        campaigns = campaign.map { new in
            campaigns.filter { $0.campaignKey != new.campaignKey } + [new]
        } ?? []
        index = TriggerIndex(campaigns)
    }

    func listeningTo(_ signal: RuleSignal) -> [CampaignModel] { index.listeningTo(signal) }
    func find(_ campaignKey: String) -> CampaignModel? { campaigns.first { $0.campaignKey == campaignKey } }
    func inAudience(_ campaign: CampaignModel) -> Bool { true }
    func capped(_ campaign: CampaignModel) -> Bool {
        if let frequency {
            return frequency.blockReason(
                campaignKey: campaign.campaignKey, policy: campaign.frequency,
                unseenCountsAsZero: campaign.rule != nil) != nil
        }
        return capped2.contains(campaign.campaignKey)
    }
    func slotCampaignKey(_ slot: String) -> String? { slots[slot] }
    var audienceContext: String { "missing" }
}

/// Flutter: `test/dmc_decision_engine_test.dart` — arbitration, the inline
/// fan-out and the wait lifecycle through the engine itself (dmc-mvp-spec
/// §3.3, §3.9–3.13). The SDK shell is replaced by a `Facts` double; the
/// picker, the evaluator, the index and the waits are the real ones.
@MainActor
@Suite("DMC decision engine", .serialized)
struct DMCDecisionEngineTests {
    private final class Clock { var now = 0 }

    private let clock = Clock()
    private let facts = Facts()
    private let sink = RecordSink()
    private var routed: Box<[String]>
    private let engine: DecisionEngine

    private final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    init() {
        let clock = clock
        let facts = facts
        let routed = Box<[String]>([])
        self.routed = routed
        engine = DecisionEngine(
            facts: facts,
            route: { campaign, _, _ in
                routed.value.append(campaign.campaignKey)
                facts.frequency?.recordShow(campaign.campaignKey, campaign.frequency)
            },
            nowMs: { clock.now }
        )
        DigiaLogger.registerSink(sink)
    }

    private var routedKeys: [String] { routed.value }

    /// Moves the injected clock, as real time would: the waits compare `now`
    /// with the end they stored.
    private func advance(_ ms: Int) {
        clock.now += ms
        engine.waits.schedule()
    }

    private func gating(_ key: String, _ reason: DiagnosticReason) -> [TimelineRecord] {
        sink.records.filter {
            $0.campaignKey == key && $0.stage == .gating && $0.reason?.wire == reason.wire
        }
    }

    private func outcomes(_ key: String) -> [String] {
        gating(key, TimelineReason.waitEnded).compactMap { $0.extras["outcome"] }
    }

    private func finish() { DigiaLogger.unregisterSink(sink) }

    // MARK: signals before the bundle is ready (R58)

    @Test("signals before the bundle is ready are held, then replayed in arrival order")
    func heldThenReplayed() {
        defer { finish() }
        facts.ready = false
        facts.add(Self.campaign("home_tip", screen: "home"))
        facts.add(Self.campaign("cart_tip", screen: "cart"))

        engine.send(.screenViewed("home"))
        engine.send(.screenViewed("cart"))
        #expect(routedKeys.isEmpty)

        facts.ready = true
        engine.ready()

        #expect(routedKeys == ["home_tip", "cart_tip"])
    }

    @Test("signals are dropped when the app backgrounds before ready")
    func droppedOnBackground() {
        defer { finish() }
        facts.ready = false
        facts.add(Self.campaign("home_tip", screen: "home"))

        engine.send(.screenViewed("home"))
        engine.dropHeld()
        facts.ready = true
        engine.ready()

        #expect(routedKeys.isEmpty)
    }

    @Test("signals are dropped, not held again, when loading fails")
    func droppedOnClose() {
        defer { finish() }
        facts.ready = false
        facts.add(Self.campaign("home_tip", screen: "home"))

        engine.send(.screenViewed("home"))
        engine.close()
        engine.send(.screenViewed("cart"))
        facts.ready = true
        engine.ready()

        #expect(routedKeys.isEmpty)
        #expect(engine.isReady)
    }

    @Test("a mounting slot is a signal a campaign can trigger on")
    func slotVisibleTriggers() {
        defer { finish() }
        facts.add(Self.campaign("slot_tip", triggers: [["type": "slot_visible", "slots": ["hero", "rail"]]]))
        engine.ready()

        engine.send(.slotVisible("rail"))

        #expect(routedKeys == ["slot_tip"])
    }

    // MARK: one winner per trigger (§3.12)

    @Test("routes the highest priority, holds the rest back with a log")
    func highestWins() {
        defer { finish() }
        facts.add(Self.campaign("low", priority: 400))
        facts.add(Self.campaign("top", priority: 1000))
        facts.add(Self.campaign("mid", priority: 600))
        engine.ready()

        engine.send(.event("cart_landed", [:]))

        #expect(routedKeys == ["top"])
        #expect(gating("mid", TimelineReason.lowerPriority).first?.extras == [
            "verdict": "eligible", "outcome": "held_back", "lost_to": "top",
        ])
        #expect(gating("mid", TimelineReason.lowerPriority).count == 1)
        #expect(gating("low", TimelineReason.lowerPriority).count == 1)
    }

    @Test("never routes a campaign whose conditions fail")
    func conditionsFail() {
        defer { finish() }
        facts.add(Self.campaign("vip", conditions: Self.planIsGold))
        facts.attributes = ["plan": "silver"]
        engine.ready()

        engine.send(.event("cart_landed", [:]))

        #expect(routedKeys.isEmpty)
        let failed = gating("vip", TimelineReason.conditionFailed)
        #expect(failed.count == 1)
        #expect(failed.first?.extras == ["verdict": "ineligible", "condition": "attribute.plan"])
    }

    @Test("reports a defaulted priority once per session, not per signal")
    func defaultedPriorityOnce() {
        defer { finish() }
        facts.add(Self.campaign("no_priority", priority: nil))
        engine.ready()

        engine.send(.event("cart_landed", [:]))
        engine.send(.event("cart_landed", [:]))

        #expect(routedKeys == ["no_priority", "no_priority"])
        let reported = sink.records.filter {
            $0.campaignKey == "no_priority" && $0.message.contains("priority")
        }
        #expect(reported.count == 1)
    }

    @Test("reports an unreadable rule once per session; reset clears it")
    func unreadableRuleOnce() {
        defer { finish() }
        facts.add(Self.campaign("future", triggers: [["type": "event_ever"]]))
        engine.ready()

        engine.send(.event("cart_landed", [:]))
        engine.send(.event("cart_landed", [:]))
        let reported = gating("future", TimelineReason.unsupportedFeature)
        #expect(reported.count == 1)
        #expect(reported.first?.extras == ["verdict": "ineligible", "feature": "event_ever"])

        engine.reset()
        engine.send(.event("cart_landed", [:]))
        #expect(gating("future", TimelineReason.unsupportedFeature).count == 2)
    }

    // MARK: inline campaigns (§3.10)

    @Test("each slot winner is routed besides the overlay winner")
    func slotWinnersBesideOverlay() {
        defer { finish() }
        facts.add(Self.campaign("nudge", priority: 900))
        facts.add(Self.inline("hero_low", "hero", priority: 400))
        facts.add(Self.inline("hero_high", "hero", priority: 800))
        facts.add(Self.inline("rail", "rail", priority: 100))
        engine.ready()

        engine.send(.event("cart_landed", [:]))

        #expect(Set(routedKeys) == ["nudge", "hero_high", "rail"])
        #expect(routedKeys.count == 3)
        #expect(gating("hero_low", TimelineReason.lowerPriority).first?.extras == [
            "verdict": "eligible", "outcome": "held_back", "lost_to": "hero_high",
        ])
    }

    @Test("a campaign already in its slot is not routed again")
    func alreadyInSlot() {
        defer { finish() }
        facts.add(Self.inline("hero", "hero"))
        facts.slots = ["hero": "hero"]
        engine.ready()

        engine.send(.event("cart_landed", [:]))

        #expect(routedKeys.isEmpty)
        let logged = sink.records.filter { $0.campaignKey == "hero" && $0.message.contains("slot") }
        #expect(logged.count == 1)
    }

    @Test("an inline campaign shows at once: its wait is ignored (W8)")
    func inlineWaitIgnored() {
        defer { finish() }
        facts.add(Self.inline("hero", "hero", waitMs: 5000))
        engine.ready()

        engine.send(.event("cart_landed", [:]))

        #expect(routedKeys == ["hero"])
        #expect(gating("hero", TimelineReason.waitStarted).isEmpty)
        advance(5000)
        #expect(routedKeys == ["hero"])
    }

    @Test("a repeating trigger re-fans out every slot")
    func repeatingFansOut() {
        defer { finish() }
        facts.add(Self.inline("hero", "hero"))
        facts.add(Self.inline("rail", "rail"))
        engine.ready()

        engine.send(.event("cart_landed", [:]))
        engine.send(.event("cart_landed", [:]))

        #expect(routedKeys == ["hero", "rail", "hero", "rail"])
    }

    // MARK: waits (§3.9, §11)

    @Test("a wait starts on the trigger and shows when the delay is over")
    func waitStartsAndShows() {
        defer { finish() }
        facts.add(Self.campaign("tip", screen: "login", waitMs: 20000))
        engine.ready()

        engine.send(.screenViewed("login"))
        #expect(routedKeys.isEmpty)
        #expect(gating("tip", TimelineReason.waitStarted).first?.extras["ms"] == "20000")

        advance(19999)
        #expect(routedKeys.isEmpty)
        advance(1)
        #expect(routedKeys == ["tip"])
        #expect(outcomes("tip") == ["checked"])
    }

    // dmc-case: dmc.wait_cancel.held_and_late_waits_log_elapsed
    @Test("a signal held while loading logs the time that is left")
    func heldSignalLogsRemaining() {
        defer { finish() }
        facts.ready = false
        facts.add(Self.campaign("tip", screen: "login", waitMs: 20000))
        engine.send(.screenViewed("login"))
        clock.now += 8000
        facts.ready = true
        engine.ready()

        let started = sink.records.filter { $0.campaignKey == "tip" && $0.message.hasPrefix("Waiting") }
        #expect(started.count == 1)
        #expect(started.first?.message.hasPrefix("Waiting 12000 ms") == true)
        advance(12000)
        #expect(sink.records.filter { $0.message.hasPrefix("Wait ended after") }.map(\.message)
            == ["Wait ended after 20000 ms"])
    }

    // dmc-case: dmc.wait_cancel.held_and_late_waits_log_elapsed
    @Test("a wait that ends late logs the time that really passed")
    func lateWaitLogsElapsed() {
        defer { finish() }
        facts.add(Self.campaign("tip", screen: "login", waitMs: 20000))
        engine.ready()
        engine.send(.screenViewed("login"))
        // The clock moves on while the timer is held, as on a sleeping phone.
        clock.now += 5000
        advance(20000)

        let ended = sink.records.filter { $0.message.hasPrefix("Wait ended after") }
        #expect(ended.map(\.message) == ["Wait ended after 25000 ms"])
        #expect(ended.first?.extras["ms"] == "20000")
    }

    @Test("a re-trigger keeps the first timer (D4) and says so")
    func retriggerKeepsFirst() {
        defer { finish() }
        facts.add(Self.campaign("tip", screen: "login", waitMs: 20000))
        engine.ready()

        engine.send(.screenViewed("login"))
        advance(15000)
        engine.send(.screenViewed("login"))

        #expect(gating("tip", TimelineReason.waitStarted).count == 1)
        #expect(gating("tip", TimelineReason.waitInProgress).count == 1)

        advance(5000)
        #expect(routedKeys == ["tip"])
        advance(30000)
        #expect(routedKeys == ["tip"])
    }

    @Test("an event cancel ends the wait before the signal is evaluated")
    func eventCancelsBeforeEvaluation() {
        defer { finish() }
        facts.add(Self.campaign(
            "tip", screen: "login", waitMs: 20000,
            cancels: [["type": "event", "name": "login_submitted"]]))
        facts.add(Self.campaign("submit_banner", triggers: [["type": "event", "name": "login_submitted"]]))
        engine.ready()

        engine.send(.screenViewed("login"))
        engine.send(.event("login_submitted", [:]))

        #expect(gating("tip", TimelineReason.waitCancelled).first?.extras == ["cause": "event"])
        #expect(routedKeys == ["submit_banner"])

        advance(20000)
        #expect(routedKeys == ["submit_banner"])
    }

    @Test("a wait blocked by a cap is dropped when it ends")
    func waitCapped() {
        defer { finish() }
        facts.add(Self.campaign("tip", screen: "login", waitMs: 1000))
        engine.ready()

        engine.send(.screenViewed("login"))
        facts.capped2 = ["tip"]
        advance(1000)

        #expect(routedKeys.isEmpty)
        #expect(gating("tip", TimelineReason.capped).count == 1)
        #expect(outcomes("tip") == ["checked"])
    }

    @Test("a wait is checked again at the end: a failed condition drops it")
    func waitRecheckedCondition() {
        defer { finish() }
        facts.add(Self.campaign("tip", screen: "login", conditions: Self.planIsGold, waitMs: 1000))
        facts.attributes = ["plan": "gold"]
        engine.ready()

        engine.send(.screenViewed("login"))
        facts.attributes = ["plan": "silver"]
        advance(1000)

        #expect(routedKeys.isEmpty)
        #expect(gating("tip", TimelineReason.conditionFailed).first?.extras == [
            "verdict": "ineligible", "condition": "attribute.plan",
        ])
        #expect(outcomes("tip") == ["checked"])
    }

    @Test("a wait is checked again at the end: a changed rule drops it")
    func waitRuleChanged() {
        defer { finish() }
        facts.add(Self.campaign("tip", screen: "login", waitMs: 1000))
        engine.ready()

        engine.send(.screenViewed("login"))
        facts.replace(Self.campaign(
            "tip", triggers: [["type": "event", "name": "somewhere_else"]], waitMs: 1000))
        advance(1000)

        #expect(routedKeys.isEmpty)
        #expect(outcomes("tip") == ["rule_changed"])
    }

    @Test("a wait is dropped when the campaign is gone from the bundle")
    func waitCampaignGone() {
        defer { finish() }
        facts.add(Self.campaign("tip", screen: "login", waitMs: 1000))
        engine.ready()

        engine.send(.screenViewed("login"))
        facts.replace(nil)
        advance(1000)

        #expect(routedKeys.isEmpty)
        #expect(outcomes("tip") == ["gone"])
    }

    @Test("a wait is dropped when the campaign moved to a CEP while waiting")
    func waitCampaignMovedToCep() throws {
        defer { finish() }
        facts.add(Self.campaign("tip", screen: "login", waitMs: 1000))
        engine.ready()

        engine.send(.screenViewed("login"))
        // The same key, now a CEP-owned campaign: the SDK no longer decides it.
        var json = Self.json(
            "tip", priority: nil,
            triggers: [["type": "screen_viewed", "names": ["login"]]], waitMs: 1000)
        json["rule"] = nil
        facts.replace(try #require(try CampaignModel.fromJson(json)))
        advance(1000)

        #expect(routedKeys.isEmpty)
        #expect(outcomes("tip") == ["gone"])
    }

    @Test("two waits ending together: the loser finds the surface busy")
    func twoWaitsEndTogether() {
        defer { finish() }
        facts.add(Self.campaign("high_tip", priority: 900, screen: "login", waitMs: 1000))
        facts.add(Self.campaign("low_tip", priority: 800, screen: "login", waitMs: 1000))
        engine.ready()

        engine.send(.screenViewed("login"))
        advance(1000)

        #expect(routedKeys == ["high_tip"])
        #expect(gating("low_tip", DropReason.surfaceBusy).first?.extras == ["blocking": "high_tip"])
        #expect(gating("low_tip", TimelineReason.waitEnded).isEmpty)
    }

    @Test("waits keep counting in the background and fire on the return")
    func waitsAcrossBackground() {
        defer { finish() }
        facts.add(Self.campaign("tip", screen: "login", waitMs: 20000))
        engine.ready()

        engine.send(.screenViewed("login"))
        engine.pause()
        advance(60000)
        #expect(routedKeys.isEmpty)

        engine.resume()
        #expect(routedKeys == ["tip"])
    }

    @Test("a session end ends every wait and drops held signals")
    func sessionEnd() {
        defer { finish() }
        facts.ready = false
        facts.add(Self.campaign("tip", screen: "login", waitMs: 20000))
        engine.send(.screenViewed("login"))
        engine.reset()
        facts.ready = true
        engine.ready()
        #expect(routedKeys.isEmpty)

        engine.send(.screenViewed("login"))
        engine.reset()
        #expect(gating("tip", TimelineReason.waitCancelled).first?.extras == ["cause": "session_ended"])
        advance(20000)
        #expect(routedKeys.isEmpty)
    }

    // MARK: fixtures

    private static let cartLanded: [[String: Any]] = [["type": "event", "name": "cart_landed"]]
    private static let planIsGold: [String: Any] = [
        "type": "attribute", "key": "plan", "op": "eq", "value": "gold",
    ]

    // MARK: server data that must not crash

    @Test("a priority beyond the Int range is logged, not a trap")
    func hugePriorityIsLogged() {
        defer { finish() }
        facts.add(Self.campaign("big", priority: 1e300, screen: "home"))
        facts.add(Self.campaign("small", priority: 1e299, screen: "home"))
        engine.ready()

        engine.send(.screenViewed("home"))

        #expect(routedKeys == ["big"])
        #expect(gating("small", TimelineReason.lowerPriority).count == 1)
    }

    @Test("a router that throws costs that show, not the app")
    func throwingRouterAfterWaitIsContained() {
        defer { finish() }
        struct Boom: Error {}
        let clock = clock
        let thrower = DecisionEngine(
            facts: facts, route: { _, _, _ in throw Boom() }, nowMs: { clock.now })
        facts.add(Self.campaign("tip", screen: "home", waitMs: 1000))
        thrower.ready()

        thrower.send(.screenViewed("home"))
        clock.now += 1000
        thrower.waits.schedule()

        let dropped = gating("tip", TimelineReason.internalError)
        #expect(dropped.count == 1)
        #expect(dropped.first?.extras["exception_class"] == "Boom")
        #expect(!thrower.waits.isWaiting("tip"))
    }

    private static func campaign(
        _ key: String,
        priority: Any? = 600,
        screen: String? = nil,
        triggers: [[String: Any]]? = nil,
        conditions: Any? = nil,
        waitMs: Int? = nil,
        cancels: [[String: Any]]? = nil,
        frequency: [String: Any]? = nil
    ) -> CampaignModel {
        try! CampaignModel.fromJson(
            json(
                key, priority: priority,
                triggers: triggers ?? (screen.map { [["type": "screen_viewed", "names": [$0]]] } ?? cartLanded),
                conditions: conditions, waitMs: waitMs, cancels: cancels, frequency: frequency))!
    }

    private static func inline(
        _ key: String, _ slot: String, priority: Any? = 600, waitMs: Int? = nil,
        frequency: [String: Any]? = nil
    ) -> CampaignModel {
        try! CampaignModel.fromJson(json(key, priority: priority, slot: slot, waitMs: waitMs, frequency: frequency))!
    }

    private static func isolatedFrequency() -> FrequencyManager {
        let defaults = UserDefaults(suiteName: "digia.dmc.test.\(UUID().uuidString)")!
        return FrequencyManager(
            storage: UserDefaultsLocalStorage(defaults: defaults).scoped("frequency"),
            sessionIdProvider: { "s1" },
            clock: { 0 })
    }

    // MARK: zero frequency caps (dmc-cases max_total_zero_never_shows,
    // max_per_window_zero_never_shows)

    @Test("a maxTotal 0 campaign never shows; the capped winner falls through")
    func zeroMaxTotalNeverShows() {
        defer { finish() }
        facts.frequency = Self.isolatedFrequency()
        facts.add(Self.campaign("c1", priority: 2, frequency: ["maxTotal": 0]))
        facts.add(Self.campaign("c2", priority: 1, frequency: ["maxTotal": 1]))
        engine.ready()

        engine.send(.event("cart_landed", [:]))
        #expect(routedKeys == ["c2"])
        #expect(gating("c1", TimelineReason.capped).count == 1)

        engine.send(.event("cart_landed", [:]))
        #expect(routedKeys == ["c2"])
        #expect(gating("c2", TimelineReason.capped).count == 1)
    }

    @Test("a maxPerWindow count 0 campaign never shows")
    func zeroWindowCountNeverShows() {
        defer { finish() }
        facts.frequency = Self.isolatedFrequency()
        facts.add(Self.campaign(
            "c1", priority: 2, frequency: ["maxPerWindow": ["count": 0, "window": "day"]]))
        facts.add(Self.campaign(
            "c2", priority: 1, frequency: ["maxPerWindow": ["count": 1, "window": "day"]]))
        engine.ready()

        engine.send(.event("cart_landed", [:]))
        #expect(routedKeys == ["c2"])
        #expect(gating("c1", TimelineReason.capped).count == 1)

        engine.send(.event("cart_landed", [:]))
        #expect(routedKeys == ["c2"])
        #expect(gating("c2", TimelineReason.capped).count == 1)
    }

    @Test("an inline campaign is never frequency-capped")
    func inlineIgnoresFrequencyCaps() {
        defer { finish() }
        facts.frequency = Self.isolatedFrequency()
        facts.add(Self.inline("c1", "s1", priority: 900, frequency: ["maxTotal": 1]))
        facts.add(Self.campaign("c3", priority: 900, frequency: ["maxTotal": 1]))
        facts.add(Self.campaign("c4", priority: 100))
        engine.ready()

        engine.send(.event("cart_landed", [:]))
        #expect(routedKeys == ["c1", "c3"])

        engine.send(.event("cart_landed", [:]))
        #expect(routedKeys == ["c1", "c3", "c1", "c4"])
        #expect(gating("c3", TimelineReason.capped).count == 1)
    }

    @Test("slot losers are still held back when the winner is already in its slot")
    func slotLosersLoggedWhenWinnerInSlot() {
        defer { finish() }
        facts.add(Self.inline("c1", "s1", priority: 900))
        facts.add(Self.inline("c2", "s1", priority: 100))
        facts.slots = ["s1": "c1"]
        engine.ready()

        engine.send(.event("cart_landed", [:]))

        #expect(routedKeys.isEmpty)
        #expect(gating("c2", TimelineReason.lowerPriority).first?.extras == [
            "verdict": "eligible", "outcome": "held_back", "lost_to": "c1",
        ])
    }

    private static func json(
        _ key: String,
        priority: Any?,
        slot: String? = nil,
        triggers: [[String: Any]]? = nil,
        conditions: Any? = nil,
        waitMs: Int? = nil,
        cancels: [[String: Any]]? = nil,
        frequency: [String: Any]? = nil
    ) -> [String: Any] {
        var rule: [String: Any] = [
            "trigger": ["any": triggers ?? cartLanded],
            "conditions": conditions ?? ["all": []],
        ]
        if let priority { rule["priority"] = priority }
        if let waitMs {
            var wait: [String: Any] = ["type": "delay", "ms": waitMs]
            if let cancels { wait["cancel"] = ["any": cancels] }
            rule["wait"] = wait
        }
        let template: [String: Any] =
            slot == nil
            ? [
                "templateType": "nudge",
                "layoutMode": "canvas",
                "container": ["displayType": "dialog"],
                "canvas": ["version": 2, "canvasWidth": 320, "canvasHeight": 200, "children": []],
                "variables": [],
            ]
            : [
                "templateType": "banner",
                "slotKey": slot as Any,
                "image": ["url": "https://cdn.example.com/a.png"],
            ]
        var out: [String: Any] = [
            "id": "id-\(key)",
            "campaignKey": key,
            "campaignType": slot == nil ? "nudge" : "inline",
            "status": "active",
            "rule": rule,
            "templateConfig": template,
        ]
        if let frequency { out["frequency"] = frequency }
        return out
    }
}
