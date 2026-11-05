import Foundation
import Testing
@testable import DigiaEngage

@MainActor
private final class ScreensFacts: DecisionFacts {
    var ready = true
    var campaigns: [CampaignModel] = []
    private var index = TriggerIndex([])

    var attributes: [String: Any] = [:]
    var device: [String: Any] = [:]
    var currentScreen = ""
    var slots: [String: String] = [:]

    @discardableResult
    func add(_ campaign: CampaignModel) -> ScreensFacts {
        campaigns.append(campaign)
        index = TriggerIndex(campaigns)
        return self
    }

    func listeningTo(_ signal: RuleSignal) -> [CampaignModel] { index.listeningTo(signal) }
    func find(_ campaignKey: String) -> CampaignModel? { campaigns.first { $0.campaignKey == campaignKey } }
    func inAudience(_ campaign: CampaignModel) -> Bool { true }
    func capped(_ campaign: CampaignModel) -> Bool { false }
    func slotCampaignKey(_ slot: String) -> String? { slots[slot] }
    var audienceContext: String { "missing" }
}

/// DMC `rule.screens`: an overlay fires only on a listed screen, a wait ending
/// off its screens is cancelled, inline campaigns ignore screens, and malformed
/// screens degrade to `malformed_rule`. Mirrors Android `DecisionEngineTest`
/// "screens" cases and Flutter `dmc_rule_wait_test.dart` screen cases.
@MainActor
@Suite("DMC rule screens", .serialized)
struct DMCRuleScreensTests {
    private final class Clock { var now = 0 }
    private final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    private final class Sink: DiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TimelineRecord] = []
        var records: [TimelineRecord] { lock.withLock { stored } }
        func accepts(_ record: TimelineRecord) -> Bool { true }
        func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
    }

    private let clock = Clock()
    private let facts = ScreensFacts()
    private let sink = Sink()
    private var routed: Box<[String]>
    private let engine: DecisionEngine

    init() {
        let clock = clock
        let facts = facts
        let routed = Box<[String]>([])
        self.routed = routed
        engine = DecisionEngine(
            facts: facts,
            route: { campaign, _, _ in routed.value.append(campaign.campaignKey) },
            nowMs: { clock.now }
        )
        DigiaLogger.registerSink(sink)
    }

    private var routedKeys: [String] { routed.value }

    private func advance(_ ms: Int) {
        clock.now += ms
        engine.waits.schedule()
    }

    private func finish() { DigiaLogger.unregisterSink(sink) }

    private func notOnTargetScreen(_ key: String) -> [TimelineRecord] {
        sink.records.filter { $0.campaignKey == key && $0.reason?.wire == "not_on_target_screen" }
    }

    // MARK: - parsing

    @Test("an empty screens list is malformed")
    func emptyScreensIsMalformed() {
        let campaign = Self.overlay("home_offer", screens: [])
        guard case .invalid(let invalid)? = campaign.rule else {
            Issue.record("expected screens: [] to be malformed")
            return
        }
        #expect(invalid.reason == .malformedRule)
    }

    @Test("a non-list screens value is malformed")
    func nonListScreensIsMalformed() {
        var json = Self.overlayJson("home_offer", screens: ["home"])
        var rule = json["rule"] as! [String: Any]
        rule["screens"] = "home"
        json["rule"] = rule
        let campaign = try! CampaignModel.fromJson(json)!
        guard case .invalid(let invalid)? = campaign.rule else {
            Issue.record("expected screens: \"home\" to be malformed")
            return
        }
        #expect(invalid.reason == .malformedRule)
    }

    // MARK: - firing

    @Test("an overlay for home does not fire while on cart")
    func overlayOffItsScreensDoesNotFire() {
        defer { finish() }
        facts.add(Self.overlay("home_offer", screens: ["home"]))
        engine.ready()

        facts.currentScreen = "cart"
        engine.send(.event("promo", [:]))

        #expect(routedKeys.isEmpty)
        #expect(notOnTargetScreen("home_offer").count == 1)
    }

    @Test("an overlay for home fires while on home")
    func overlayOnItsScreensFires() {
        defer { finish() }
        facts.add(Self.overlay("home_offer", screens: ["home"]))
        engine.ready()

        facts.currentScreen = "home"
        engine.send(.event("promo", [:]))

        #expect(routedKeys == ["home_offer"])
    }

    @Test("screen matching is exact")
    func screenMatchIsExact() {
        defer { finish() }
        facts.add(Self.overlay("home_offer", screens: ["Home"]))
        engine.ready()

        facts.currentScreen = "home"
        engine.send(.event("promo", [:]))

        #expect(routedKeys.isEmpty)
        #expect(notOnTargetScreen("home_offer").count == 1)
    }

    @Test("an inline campaign ignores screens")
    func inlineIgnoresScreens() {
        defer { finish() }
        facts.add(Self.inline("hero_offer", slot: "hero", screens: ["home"]))
        engine.ready()

        facts.currentScreen = "cart"
        engine.send(.event("promo", [:]))

        #expect(routedKeys == ["hero_offer"])
    }

    // MARK: - waits

    @Test("a wait ending off its screens is cancelled")
    func waitEndingOffItsScreensIsCancelled() {
        defer { finish() }
        facts.add(Self.overlay("home_offer", screens: ["home"], waitMs: 1000))
        engine.ready()

        facts.currentScreen = "home"
        engine.send(.event("promo", [:]))
        #expect(routedKeys.isEmpty)

        facts.currentScreen = "cart"
        advance(2000)

        #expect(routedKeys.isEmpty)
        #expect(
            sink.records.contains {
                $0.campaignKey == "home_offer" && $0.reason?.wire == "wait_cancelled"
                    && $0.extras["cause"] == "not_on_target_screen"
            })
    }

    // MARK: - fixtures

    static func overlay(
        _ key: String, screens: [String]?, waitMs: Int? = nil
    ) -> CampaignModel {
        try! CampaignModel.fromJson(overlayJson(key, screens: screens, waitMs: waitMs))!
    }

    static func overlayJson(
        _ key: String, screens: [String]?, waitMs: Int? = nil
    ) -> [String: Any] {
        var rule: [String: Any] = [
            "trigger": ["any": [["type": "event", "name": "promo"]]],
            "conditions": ["all": []],
            "priority": 600,
        ]
        if let screens { rule["screens"] = screens }
        if let waitMs { rule["wait"] = ["type": "delay", "ms": waitMs] }
        return [
            "id": "id-\(key)",
            "campaignKey": key,
            "campaignType": "nudge",
            "rule": rule,
            "templateConfig": [
                "templateType": "nudge",
                "layoutMode": "canvas",
                "container": ["displayType": "dialog"],
                "canvas": ["version": 2, "canvasWidth": 320, "canvasHeight": 200, "children": []],
                "variables": [],
            ],
        ]
    }

    static func inline(_ key: String, slot: String, screens: [String]?) -> CampaignModel {
        var json = overlayJson(key, screens: screens)
        json["campaignType"] = "inline"
        json["templateConfig"] = [
            "templateType": "banner",
            "slotKey": slot,
            "image": ["url": "https://cdn.example.com/a.png"],
        ]
        return try! CampaignModel.fromJson(json)!
    }
}
