import Foundation
import Testing
@testable import DigiaEngage

/// Port of Flutter `test/dmc_rule_evaluator_test.dart`. Names and scenarios
/// mirror the Dart suite one to one.
@Suite("DMC rule evaluator")
struct DMCRuleEvaluatorTests {

    // MARK: - Fixtures

    static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func fixture(_ name: String) -> Any? {
        let url = fixturesDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Helpers

    static func signal(_ json: [String: Any]) -> RuleSignal {
        switch json["type"] as? String {
        case "screen_viewed":
            return .screenViewed(json["name"] as? String ?? "")
        case "event":
            return .event(
                json["name"] as? String ?? "",
                (json["properties"] as? [String: Any]) ?? [:])
        default:
            return .appOpened
        }
    }

    static func verdictName(_ verdict: RuleVerdict) -> String {
        switch verdict.kind {
        case .eligible: return "eligible"
        case .notTriggered: return "not_triggered"
        case .ineligible: return "ineligible"
        }
    }

    static func run(
        _ rule: Any?,
        attributes: [String: Any] = [:],
        signal: RuleSignal = .appOpened,
        device: [String: Any] = ["platform": "android"]
    ) -> RuleVerdict {
        RuleEvaluator.evaluate(
            parseRule(rule), signal, attributes: attributes, device: device)
    }

    static func rule(
        _ conditions: Any?,
        trigger: Any? = nil,
        wait: Any? = nil
    ) -> [String: Any] {
        var json: [String: Any] = [
            "priority": 600,
            "trigger": ["any": trigger ?? [["type": "app_opened"]]],
            "conditions": conditions,
        ]
        if let wait { json["wait"] = wait }
        return json
    }

    // MARK: - dmc_rule_vectors.json

    struct VectorCase: Sendable, CustomTestStringConvertible {
        let name: String
        let ruleJSON: String
        let signalJSON: String
        let attributesJSON: String
        let deviceJSON: String
        let expectedVerdict: String
        let expectedReason: String?

        var testDescription: String { name }
    }

    static var vectorCases: [VectorCase] {
        guard let list = fixture("dmc_rule_vectors.json") as? [[String: Any]] else { return [] }
        return list.compactMap { vector in
            guard let name = vector["name"] as? String else { return nil }
            let expected = vector["expect"] as? [String: Any] ?? [:]
            return VectorCase(
                name: name,
                ruleJSON: jsonString(vector["rule"]),
                signalJSON: jsonString(vector["signal"]),
                attributesJSON: jsonString(vector["attributes"] ?? [:]),
                deviceJSON: jsonString(vector["device"] ?? [:]),
                expectedVerdict: expected["verdict"] as? String ?? "",
                expectedReason: expected["reason"] as? String
            )
        }
    }

    private static func jsonString(_ value: Any?) -> String {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private static func jsonObject(_ string: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(string.utf8))
    }

    @Test("dmc_rule_vectors.json has at least 60 vectors with unique names")
    func vectorCount() throws {
        try #require(Self.fixture("dmc_rule_vectors.json") != nil)
        #expect(Self.vectorCases.count >= 60)
        #expect(Set(Self.vectorCases.map(\.name)).count == Self.vectorCases.count)
    }

    @Test("dmc_rule_vectors.json", arguments: vectorCases)
    func vectors(_ vector: VectorCase) {
        let signalJSON = Self.jsonObject(vector.signalJSON) as? [String: Any] ?? [:]
        let attributes = Self.jsonObject(vector.attributesJSON) as? [String: Any] ?? [:]
        let device = Self.jsonObject(vector.deviceJSON) as? [String: Any] ?? [:]
        let verdict = Self.run(
            Self.jsonObject(vector.ruleJSON),
            attributes: attributes,
            signal: Self.signal(signalJSON),
            device: device)
        #expect(Self.verdictName(verdict) == vector.expectedVerdict)
        #expect(verdict.reason?.wire == vector.expectedReason)
    }

    // MARK: - dmc_rule_spec.json

    @Test("limits and device keys match")
    func specLimits() throws {
        let spec = try #require(Self.fixture("dmc_rule_spec.json") as? [String: Any])
        let limits = spec["limits"] as? [String: Any] ?? [:]
        let deviceKeys = spec["deviceKeys"] as? [String: Any] ?? [:]
        #expect(maxRuleDepth == (limits["maxRuleDepth"] as? Int ?? -1))
        #expect(ruleDeviceKeys == Set(deviceKeys.keys))
    }

    @Test("version keys compare as versions")
    func specVersionKeys() throws {
        let spec = try #require(Self.fixture("dmc_rule_spec.json") as? [String: Any])
        let deviceKeys = spec["deviceKeys"] as? [String: Any] ?? [:]
        for (key, kind) in deviceKeys {
            let leaf: [String: Any] = [
                "type": "device", "key": key, "op": "gt", "value": "1.0",
            ]
            #expect(Self.parses(Self.rule(leaf)) == ((kind as? String) == "version"), "\(key)")
        }
    }

    @Test("the parser accepts exactly the device operators")
    func specOperators() throws {
        let spec = try #require(Self.fixture("dmc_rule_spec.json") as? [String: Any])
        let values: [String: Any?] = [
            "in": ["x"], "gt": 1, "gte": 1, "lt": 1, "lte": 1, "exists": nil,
        ]
        let ops = spec["deviceOperators"] as? [String] ?? []
        let negated = (spec["negatedOperators"] as? [String: Any] ?? [:]).keys
        for op in ops + negated {
            let leaf: [String: Any] = [
                "type": "attribute", "key": "k", "op": op,
                "value": values[op] ?? "x",
            ]
            #expect(Self.parses(Self.rule(leaf)) == ops.contains(op), "\(op)")
        }
    }

    static func parses(_ rule: Any?) -> Bool {
        if case .valid = parseRule(rule) { return true }
        return false
    }

    // MARK: - parseRule

    @Test("never throws on any JSON shape")
    func neverThrows() {
        for input in [nil, 1, "x", [], [:], ["schema": NSNull()]] as [Any?] {
            if case .valid = parseRule(input) {
                Issue.record("\(String(describing: input)) parsed as valid")
            }
        }
    }

    @Test("keeps priority, triggers and conditions")
    func keepsFields() throws {
        var json = Self.rule(
            ["all": []],
            trigger: [
                ["type": "app_opened"],
                ["type": "screen_viewed", "names": ["Cart"]],
                [
                    "type": "event", "name": "cart_landed",
                    "where": [
                        "any": [
                            ["type": "prop", "key": "total", "op": "gt", "value": 1],
                        ]
                    ],
                ],
            ])
        json["priority"] = 801
        guard case .valid(let rule) = parseRule(json) else {
            Issue.record("expected a valid rule")
            return
        }
        #expect(rule.priority == 801)
        #expect(!rule.priorityDefaulted)
        guard case .appOpened = rule.triggers[0] else {
            Issue.record("expected app_opened")
            return
        }
        guard case .screenViewed(let names) = rule.triggers[1] else {
            Issue.record("expected screen_viewed")
            return
        }
        #expect(names == ["Cart"])
        guard case .event(let name, let whereClause?) = rule.triggers[2] else {
            Issue.record("expected event")
            return
        }
        #expect(name == "cart_landed")
        guard case .any(let children) = whereClause,
              case .comparison(let comparison) = children.first
        else {
            Issue.record("expected an any node with a comparison")
            return
        }
        #expect(comparison.source == .prop)
        guard case .all = rule.conditions else {
            Issue.record("expected all conditions")
            return
        }
    }

    @Test("a missing or invalid priority counts as 600, not a malformed rule")
    func invalidPriority() throws {
        for priority in [nil, "high", Double.nan, Double.infinity] as [Any?] {
            var json = Self.rule(["all": []])
            json["priority"] = priority
            guard case .valid(let rule) = parseRule(json) else {
                Issue.record("expected a valid rule for \(String(describing: priority))")
                continue
            }
            #expect(rule.priority == 600)
            #expect(rule.priorityDefaulted)
        }
    }

    @Test("an InvalidRule carries a detail for the log")
    func invalidDetail() {
        var json = Self.rule(["all": []])
        json["trigger"] = ["any": "cart"]
        guard case .invalid(let rule) = parseRule(json) else {
            Issue.record("expected an invalid rule")
            return
        }
        #expect(rule.detail.contains("trigger"))
    }

    @Test("an empty trigger list never triggers")
    func emptyTrigger() {
        let verdict = Self.run(Self.rule(["all": []], trigger: []), attributes: [:])
        #expect(verdict.kind == .notTriggered)
    }

    // MARK: - operators

    func leaf(_ op: String, _ value: Any?, _ actual: Any?) -> RuleVerdictKind {
        Self.run(
            Self.rule([
                "type": "attribute", "key": "k", "op": op, "value": value ?? NSNull(),
            ]),
            attributes: actual.map { ["k": $0] } ?? [:]
        ).kind
    }

    @Test("eq and neq need the same JSON type")
    func eqNeq() {
        #expect(leaf("eq", 2, 2.0) == .eligible)
        #expect(leaf("eq", "a", "a") == .eligible)
        #expect(leaf("eq", false, false) == .eligible)
        #expect(leaf("eq", 2, "2") == .ineligible)
        #expect(leaf("neq", 2, "2") == .eligible)
        #expect(leaf("neq", "a", "a") == .ineligible)
    }

    @Test("in matches one list element")
    func inList() {
        #expect(leaf("in", ["a", "b"], "b") == .eligible)
        #expect(leaf("in", [1, 2], 2.0) == .eligible)
        #expect(leaf("in", ["1"], 1) == .ineligible)
    }

    @Test("contains checks substrings and list members")
    func contains() {
        #expect(leaf("contains", "ol", "gold") == .eligible)
        #expect(leaf("contains", "x", ["x", "y"]) == .eligible)
        #expect(leaf("contains", "z", ["x", "y"]) == .ineligible)
        #expect(leaf("contains", "x", 5) == .ineligible)
    }

    @Test("numeric ops accept numbers and numeric strings only")
    func numericOps() {
        #expect(leaf("gt", 1, 2) == .eligible)
        #expect(leaf("gte", 2, 2) == .eligible)
        #expect(leaf("lt", 2, "1.5") == .eligible)
        #expect(leaf("lte", 0, "-1") == .eligible)
        #expect(leaf("gt", 1, "1e3") == .ineligible)
        #expect(leaf("gt", 1, true) == .ineligible)
        #expect(leaf("gt", 1, Double.nan) == .ineligible)
    }

    @Test("exists is true for every non-null value")
    func exists() {
        #expect(leaf("exists", nil, "") == .eligible)
        #expect(leaf("exists", nil, 0) == .eligible)
        #expect(leaf("exists", nil, nil) == .ineligible)
    }

    @Test("every op is false for a missing value")
    func missingValue() {
        for op in ["eq", "neq", "in", "contains", "gt", "exists"] {
            let value: Any? = op == "in" ? ["a"] : (op == "gt" ? 1 : "a")
            #expect(leaf(op, value, nil) == .ineligible, "\(op)")
        }
    }

    // MARK: - plain part names

    @Test("a plain-name part with an unknown type skips the campaign")
    func unknownType() {
        let cases: [(String, [String: Any], IneligibleReason)] = [
            (
                "trigger",
                Self.rule(["all": []], trigger: [["type": "app_opened@1"]]),
                .unsupportedFeature
            ),
            (
                "leaf",
                Self.rule(["type": "attribute@1", "key": "k", "op": "eq", "value": "x"]),
                .unsupportedFeature
            ),
            (
                "event where",
                Self.rule(
                    ["all": []],
                    trigger: [
                        [
                            "type": "event", "name": "e",
                            "where": ["type": "prop@1", "key": "k", "op": "eq", "value": 1],
                        ]
                    ]),
                .unsupportedFeature
            ),
            (
                "unknown trigger",
                Self.rule(["all": []], trigger: [["type": "idle"]]),
                .unsupportedFeature
            ),
        ]
        for (place, rule, reason) in cases {
            guard case .invalid(let parsed) = parseRule(rule) else {
                Issue.record("expected an invalid rule for \(place)")
                continue
            }
            #expect(parsed.reason == reason, "\(place)")
        }
    }

    @Test("a leftover schema or requires key is ignored")
    func leftoverKeys() {
        var json = Self.rule(["all": []])
        json["schema"] = "dmc_rule@1"
        json["requires"] = ["dmc_rule@1", "future@9"]
        #expect(Self.parses(json))
    }

    @Test("a rule using a part this SDK does not know is skipped, never thrown on")
    func newerPart() {
        var json = Self.rule(["all": []], trigger: [["type": "app_opened@2"]])
        json["schema"] = "dmc_rule@2"
        json["requires"] = ["app_opened@2"]
        guard case .invalid(let parsed) = parseRule(json) else {
            Issue.record("expected an invalid rule")
            return
        }
        #expect(parsed.reason == .unsupportedFeature)
        let verdict = RuleEvaluator.evaluate(
            parseRule(json), .appOpened, attributes: [:], device: [:])
        #expect(verdict.reason == .unsupportedFeature)
    }

    @Test("bad trigger shapes and unknown names have different reasons")
    func malformedShapes() {
        let cases: [(String, [String: Any], IneligibleReason)] = [
            (
                "a key list with a null in it",
                Self.rule(["all": []], trigger: [["type": "anchor_visible", "keys": [NSNull()]]]),
                .malformedRule
            ),
            (
                "an empty key list",
                Self.rule(["all": []], trigger: [["type": "anchor_visible", "keys": []]]),
                .malformedRule
            ),
            (
                "a non-list key field",
                Self.rule(["all": []], trigger: [["type": "slot_visible", "slots": "hero"]]),
                .malformedRule
            ),
            (
                "a space-only screen name",
                Self.rule(["all": []], trigger: [["type": "screen_viewed", "names": [""]]]),
                .malformedRule
            ),
            (
                "a numeric event name",
                Self.rule(["all": []], trigger: [["type": "event", "name": 7]]),
                .malformedRule
            ),
            (
                "a type that is not a string",
                Self.rule(["all": []], trigger: [["type": 7]]),
                .malformedRule
            ),
            (
                "a trigger this SDK has never heard of",
                Self.rule(["all": []], trigger: [["type": "idle"]]),
                .unsupportedFeature
            ),
        ]
        for (name, rule, reason) in cases {
            guard case .invalid(let parsed) = parseRule(rule) else {
                Issue.record("expected an invalid rule for \(name)")
                continue
            }
            #expect(parsed.reason == reason, "\(name)")
        }
    }

    @Test("a wait with a non-finite ms is malformed, not a crash")
    func nonFiniteWait() {
        let parsed = parseRule(
            Self.rule(
                ["all": []], trigger: [["type": "app_opened"]],
                wait: ["type": "delay", "ms": Double.infinity]))
        guard case .invalid(let rule) = parsed else {
            Issue.record("expected an invalid rule")
            return
        }
        #expect(rule.reason == .malformedRule)
    }

    // MARK: - evaluation beyond the vectors

    static func runWith(
        _ rule: Any?,
        _ signal: RuleSignal,
        attributes: [String: Any] = [:],
        device: [String: Any] = [:]
    ) -> RuleVerdict {
        RuleEvaluator.evaluate(
            parseRule(rule), signal, attributes: attributes, device: device)
    }

    static func trigger(_ trigger: Any?, _ signal: RuleSignal) -> RuleVerdictKind {
        runWith(rule(["all": []], trigger: [trigger]), signal).kind
    }

    @Test("app_foregrounded and app_opened are different moments")
    func foregroundVsOpened() {
        let foreground: [String: Any] = ["type": "app_foregrounded"]
        #expect(Self.trigger(foreground, .appForegrounded) == .eligible)
        #expect(Self.trigger(foreground, .appOpened) == .notTriggered)
        #expect(Self.trigger(["type": "app_opened"], .appForegrounded) == .notTriggered)
    }

    @Test("anchor_visible and slot_visible match one listed key")
    func visibilityTriggers() {
        #expect(Self.trigger(["type": "anchor_visible", "keys": ["cta", "buy"]], .anchorVisible("buy")) == .eligible)
        #expect(Self.trigger(["type": "anchor_visible", "keys": ["cta"]], .anchorVisible("other")) == .notTriggered)
        #expect(Self.trigger(["type": "slot_visible", "slots": ["hero"]], .slotVisible("hero")) == .eligible)
        #expect(Self.trigger(["type": "slot_visible", "slots": ["hero"]], .slotVisible("rail")) == .notTriggered)
    }

    @Test("app_opens reads the device counter: null fails, eq and gte compare")
    func appOpensCondition() {
        func condition(_ op: String, _ value: Any) -> [String: Any] {
            ["type": "device", "key": "app_opens", "op": op, "value": value]
        }
        func at(_ actual: Any?, _ op: String, _ value: Any) -> RuleVerdictKind {
            var device: [String: Any] = [:]
            if let actual { device["app_opens"] = actual }
            return Self.runWith(
                Self.rule(condition(op, value)), .appOpened, device: device
            ).kind
        }
        #expect(at(1, "eq", 1) == .eligible)
        #expect(at(2, "eq", 1) == .ineligible)
        #expect(at(nil, "gte", 1) == .ineligible)
        #expect(at(5, "gte", 1) == .eligible)
        #expect(at("5", "gte", 1) == .eligible)
        #expect(at(1, "gte", 2) == .ineligible)
    }

    @Test("a version part is a number: 5.10 is above 5.9")
    func versionComparisons() {
        func appVersion(_ actual: Any?, _ op: String, _ value: String) -> RuleVerdictKind {
            var device: [String: Any] = [:]
            if let actual { device["app_version"] = actual }
            return Self.runWith(
                Self.rule([
                    "type": "device", "key": "app_version", "op": op, "value": value,
                ]),
                .appOpened, device: device
            ).kind
        }
        #expect(appVersion("5.10", "gte", "5.9") == .eligible)
        #expect(appVersion("5.9", "gte", "5.10") == .ineligible)
        #expect(appVersion("5.10.0", "eq", "5.10") == .eligible)
        #expect(appVersion("2.17.3-beta", "gt", "2.17.2+41") == .eligible)
    }

    @Test("a list compares with a list element by element")
    func listComparison() {
        #expect(
            Self.runWith(
                Self.rule(["type": "attribute", "key": "tags", "op": "eq", "value": ["a", "b"]]),
                .appOpened, attributes: ["tags": ["a", "b"]]
            ).kind == .eligible)
        #expect(
            Self.runWith(
                Self.rule(["type": "attribute", "key": "tags", "op": "eq", "value": ["a"]]),
                .appOpened, attributes: ["tags": ["a", "b"]]
            ).kind == .ineligible)
        #expect(
            Self.runWith(
                Self.rule([
                    "type": "attribute", "key": "cart", "op": "in", "value": [["a"], ["a", "b"]],
                ]),
                .appOpened, attributes: ["cart": ["a", "b"]]
            ).kind == .eligible)
    }

    @Test("not_in and not_exists are not nodes around the positive operator")
    func negatedByNot() {
        func cities(_ actual: Any?, _ op: String, _ value: Any?) -> RuleVerdictKind {
            var attributes: [String: Any] = [:]
            if let actual { attributes["city"] = actual }
            return Self.runWith(
                Self.rule([
                    "all": [
                        [
                            "not": [
                                "type": "attribute", "key": "city", "op": op,
                                "value": value ?? NSNull(),
                            ]
                        ]
                    ]
                ]),
                .appOpened, attributes: attributes
            ).kind
        }
        #expect(cities("Nashik", "in", ["Pune", "Mumbai"]) == .eligible)
        #expect(cities("Pune", "in", ["Pune", "Mumbai"]) == .ineligible)
        #expect(cities(nil, "in", ["Pune", "Mumbai"]) == .eligible)
        #expect(cities(nil, "exists", nil) == .eligible)
        #expect(cities("Pune", "exists", nil) == .ineligible)
    }

    @Test("S14: an AND of OR groups over an attribute, a prop and the device")
    func s14() {
        let rule = Self.rule(
            [
                "all": [
                    [
                        "any": [
                            ["type": "attribute", "key": "city", "op": "in", "value": ["Pune", "Mumbai"]],
                            ["type": "device", "key": "app_version", "op": "gte", "value": "4.2.0"],
                        ]
                    ],
                    ["not": ["type": "attribute", "key": "plan", "op": "eq", "value": "gold"]],
                ]
            ],
            trigger: [
                [
                    "type": "event", "name": "cart_landed",
                    "where": ["type": "prop", "key": "cart_total", "op": "gte", "value": 500],
                ]
            ])
        func verdict(_ attributes: [String: Any], _ total: Any?) -> RuleVerdictKind {
            var properties: [String: Any] = [:]
            if let total { properties["cart_total"] = total }
            return Self.runWith(
                rule, .event("cart_landed", properties),
                attributes: attributes, device: ["app_version": "4.1.0"]
            ).kind
        }
        #expect(verdict(["city": "Pune"], 500) == .eligible)
        #expect(verdict(["city": "Mumbai"], 800) == .eligible)
        #expect(verdict(["city": "Nashik"], 800) == .ineligible)
        #expect(verdict(["city": "Pune"], 499) == .notTriggered)
        #expect(verdict(["city": "Nashik", "plan": "gold"], 500) == .ineligible)
        #expect(
            Self.runWith(
                rule, .event("cart_landed", ["cart_total": 500]),
                attributes: ["city": "Nashik"], device: ["app_version": "4.2.0"]
            ).kind == .eligible)
    }

    @Test("the failure detail names the top-level shape that failed")
    func failureDetail() throws {
        let attributeLeaf: [String: Any] = [
            "type": "attribute", "key": "k", "op": "eq", "value": "x",
        ]
        let anyVerdict = Self.runWith(
            Self.rule(["any": [attributeLeaf]]), .appOpened)
        #expect(anyVerdict.detail == "any")
        let notVerdict = Self.runWith(
            Self.rule(["not": attributeLeaf]), .appOpened, attributes: ["k": "x"])
        #expect(notVerdict.detail == "not")
        let allVerdict = Self.runWith(
            Self.rule(["all": [["all": [attributeLeaf]]]]), .appOpened)
        #expect(allVerdict.detail == "all")
        let mixed = Self.runWith(
            Self.rule([
                "any": [
                    attributeLeaf,
                    ["type": "device", "key": "platform", "op": "eq", "value": "ios"],
                ]
            ]),
            .appOpened, device: ["platform": "android"])
        #expect(mixed.detail == "any")
    }

    @Test("the evaluator never throws on a rule the parser would reject")
    func evaluatorNeverThrows() {
        let broken = ValidRule(
            priority: 600,
            priorityDefaulted: false,
            triggers: [.appOpened],
            conditions: .comparison(
                Comparison(source: .attribute, key: "k", op: .gt, value: "not-a-number")),
            wait: nil)
        let verdict = RuleEvaluator.evaluate(
            .valid(broken), .appOpened, attributes: ["k": 5], device: [:])
        #expect(verdict.kind == .ineligible)
        #expect(verdict.reason == .malformedRule)
        #expect(!(verdict.detail ?? "").isEmpty)
    }
}
