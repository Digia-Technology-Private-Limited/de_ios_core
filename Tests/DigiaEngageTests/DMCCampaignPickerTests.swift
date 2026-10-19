import Foundation
import Testing
@testable import DigiaEngage

/// Port of Flutter `test/dmc_campaign_picker_test.dart`.
@Suite("DMC campaign picker")
struct DMCCampaignPickerTests {

    static func pick(
        _ campaigns: [CampaignModel],
        isWaiting: (String) -> Bool = { _ in false },
        inAudience: (CampaignModel) -> Bool = { _ in true },
        capped: (CampaignModel) -> Bool = { _ in false }
    ) -> RuleDecision {
        pickCampaign(
            campaigns,
            signal: .event("cart_landed", [:]),
            attributes: [:],
            device: [:],
            isWaiting: isWaiting,
            inAudience: inAudience,
            capped: capped)
    }

    static func order(_ decision: RuleDecision) -> [String?] {
        [decision.winner?.campaignKey] + decision.heldBack.map(\.campaignKey)
    }

    static func slots(_ decision: RuleDecision) -> [String] {
        decision.inlineWinners.map { "\($0.slot):\($0.campaign.campaignKey)" }
    }

    @Test("the highest priority wins; the rest are held back highest first")
    func highestPriorityWins() {
        let decision = Self.pick([
            Self.campaign("low", 400),
            Self.campaign("top", 1000),
            Self.campaign("mid", 600),
        ])
        #expect(Self.order(decision) == ["top", "mid", "low"])
    }

    @Test("a tie goes to the campaign key that sorts first")
    func tieByKey() {
        let decision = Self.pick([
            Self.campaign("b_tip", 600),
            Self.campaign("B_tip", 600),
            Self.campaign("a_tip", 600),
        ])
        // Code-unit order: uppercase sorts before lowercase.
        #expect(Self.order(decision) == ["B_tip", "a_tip", "b_tip"])
    }

    @Test("a missing or invalid priority counts as 600")
    func defaultPriority() {
        let decision = Self.pick([
            Self.campaign("missing", nil),
            Self.campaign("above", 601),
            Self.campaign("invalid", "high"),
            Self.campaign("below", 599),
        ])
        #expect(Self.order(decision) == ["above", "invalid", "missing", "below"])
        var defaulted: [String: Bool] = [:]
        for campaign in [decision.winner!] + decision.heldBack {
            if case .valid(let rule)? = campaign.rule {
                defaulted[campaign.campaignKey] = rule.priorityDefaulted
            }
        }
        #expect(
            defaulted == [
                "above": false, "invalid": true, "missing": true, "below": false,
            ])
    }

    // MARK: - inline campaigns (D5)

    @Test("one winner per slot, besides the single overlay winner")
    func inlineSlots() {
        let decision = Self.pick([
            Self.campaign("nudge_a", 600),
            Self.campaign("nudge_b", 900),
            Self.inline("hero_low", "hero", 400),
            Self.inline("hero_high", "hero", 800),
            Self.inline("rail", "rail", 100),
        ])
        #expect(decision.winner?.campaignKey == "nudge_b")
        #expect(Self.slots(decision) == ["hero:hero_high", "rail:rail"])
        #expect(
            decision.inlineWinners.first?.heldBack.map(\.campaignKey) == ["hero_low"])
    }

    @Test("a tie in a slot goes to the campaign key that sorts first")
    func inlineTie() {
        let decision = Self.pick([
            Self.inline("b_hero", "hero", 600),
            Self.inline("a_hero", "hero", 600),
        ])
        #expect(Self.slots(decision) == ["hero:a_hero"])
    }

    @Test("inline does not take the overlay winner place")
    func inlineDoesNotWinOverlay() {
        let decision = Self.pick([Self.inline("hero", "hero", 1000)])
        #expect(decision.winner == nil)
        #expect(Self.slots(decision) == ["hero:hero"])
    }

    @Test("a wait on an inline campaign is ignored")
    func inlineWaitIgnored() {
        let decision = Self.pick([
            Self.inline("hero", "hero", 400, wait: true),
            Self.campaign("nudge", 900),
        ])
        #expect(Self.slots(decision) == ["hero:hero"])
        #expect(decision.waiting.isEmpty)
        #expect(decision.winner?.campaignKey == "nudge")
    }

    // MARK: - ineligible campaigns (§4.5)

    @Test("each verdict becomes its own gating reason")
    func verdictReasons() {
        let decision = Self.pick(
            [
                Self.campaign(
                    "failed", 600,
                    conditions: [
                        "type": "attribute", "key": "plan", "op": "eq", "value": "gold",
                    ]),
                Self.campaign("broken", 900, triggers: [["type": "event_ever"]]),
                Self.campaign("malformed", 900, conditions: "vip"),
                Self.campaign("gated", 900),
                Self.campaign("capped", 900),
            ],
            inAudience: { $0.campaignKey != "gated" },
            capped: { $0.campaignKey == "capped" })

        #expect(decision.winner == nil)
        #expect(decision.heldBack.isEmpty)
        var reasons: [String: TimelineReason] = [:]
        for skip in decision.skipped {
            if case .ineligible(let campaign, let reason, _) = skip {
                reasons[campaign.campaignKey] = reason
            }
        }
        #expect(
            reasons == [
                "failed": .conditionFailed,
                "broken": .unsupportedFeature,
                "malformed": .malformedRule,
                "gated": .notInAudience,
                "capped": .capped,
            ])
        var failedDetail: String?
        for skip in decision.skipped {
            if case .ineligible(let campaign, _, let detail) = skip,
               campaign.campaignKey == "failed"
            {
                failedDetail = detail
            }
        }
        #expect(failedDetail == "attribute.plan")
    }

    @Test("a campaign whose rule fails never falls back to a lower one")
    func noFallback() {
        let decision = Self.pick([
            Self.campaign("broken", 900, conditions: "vip"),
            Self.campaign("fine", 400),
        ])
        #expect(decision.winner?.campaignKey == "fine")
        #expect(decision.skipped.count == 1)
        if case .ineligible(let campaign, _, _) = decision.skipped.first {
            #expect(campaign.campaignKey == "broken")
        }
    }

    @Test("a campaign already waiting reports already_waiting, not held_back")
    func alreadyWaiting() {
        let decision = Self.pick(
            [
                Self.campaign("waiting", 900, wait: ["type": "delay", "ms": 1000]),
                Self.campaign("fresh", 400, wait: ["type": "delay", "ms": 5000]),
            ],
            isWaiting: { $0 == "waiting" })

        guard case .alreadyWaiting(let campaign)? = decision.skipped.first else {
            Issue.record("expected already_waiting")
            return
        }
        #expect(campaign.campaignKey == "waiting")
        #expect(decision.waiting.count == 1)
        #expect(decision.waiting.first?.0.campaignKey == "fresh")
        #expect(decision.heldBack.isEmpty)
        #expect(decision.winner == nil)
    }

    @Test("a campaign with no rule belongs to a CEP and is left alone")
    func cepCampaign() {
        var json = Self.campaignJson("cep_owned", 900)
        json["rule"] = NSNull()
        let cep = try! CampaignModel.fromJson(json)!
        let decision = Self.pick([cep, Self.campaign("ours", 600)])
        #expect(decision.skipped.isEmpty)
        #expect(decision.winner?.campaignKey == "ours")
    }

    @Test("evaluateOne answers for a Digia campaign and nil for a CEP one")
    func evaluateOneOwnership() {
        let ours = Self.campaign("ours", 600)
        var json = Self.campaignJson("cep_owned", 900)
        json["rule"] = NSNull()
        let cep = try! CampaignModel.fromJson(json)!
        #expect(
            evaluateOne(
                ours, trigger: .event("cart_landed", [:]),
                attributes: [:], device: [:])?.kind == .eligible)
        #expect(
            evaluateOne(
                cep, trigger: .event("cart_landed", [:]),
                attributes: [:], device: [:]) == nil)
    }

    // MARK: - Fixtures

    static func campaign(
        _ key: String,
        _ priority: Any?,
        conditions: Any? = nil,
        triggers: [[String: Any]]? = nil,
        wait: [String: Any]? = nil
    ) -> CampaignModel {
        try! CampaignModel.fromJson(
            campaignJson(
                key, priority, conditions: conditions, triggers: triggers, wait: wait)
        )!
    }

    static func campaignJson(
        _ key: String,
        _ priority: Any?,
        conditions: Any? = nil,
        triggers: [[String: Any]]? = nil,
        wait: [String: Any]? = nil
    ) -> [String: Any] {
        var rule: [String: Any] = [
            "trigger": ["any": triggers ?? [["type": "event", "name": "cart_landed"]]],
            "conditions": conditions ?? ["all": []],
        ]
        if let priority { rule["priority"] = priority }
        if let wait { rule["wait"] = wait }
        return [
            "id": "id-\(key)",
            "campaignKey": key,
            "campaignType": "nudge",
            "rule": rule,
            "templateConfig": [
                "templateType": "nudge",
                "layoutMode": "canvas",
                "container": ["displayType": "dialog"],
                "canvas": [
                    "version": 2,
                    "canvasWidth": 320,
                    "canvasHeight": 200,
                    "children": [],
                ],
                "variables": [],
            ],
        ]
    }

    static func inline(
        _ key: String, _ slot: String, _ priority: Any?, wait: Bool = false
    ) -> CampaignModel {
        var json = campaignJson(key, priority)
        json["campaignType"] = "inline"
        json["templateConfig"] = [
            "templateType": "banner",
            "slotKey": slot,
            "image": ["url": "https://cdn.example.com/a.png"],
        ]
        if wait {
            var rule = json["rule"] as? [String: Any] ?? [:]
            rule["wait"] = ["type": "delay", "ms": 5000]
            json["rule"] = rule
        }
        return try! CampaignModel.fromJson(json)!
    }
}
