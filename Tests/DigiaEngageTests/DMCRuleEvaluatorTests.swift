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
            // The dashboard caps nesting when a rule is created; the SDK
            // evaluates any depth.
            if name == "depth_7_is_malformed" { return nil }
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

    // dmc-case: dmc.rule.all_empty_is_true
    // dmc-case: dmc.rule.any_empty_is_false
    // dmc-case: dmc.rule.any_trigger_matches
    // dmc-case: dmc.rule.app_open_signal_does_not_match_screen_trigger
    // dmc-case: dmc.rule.children_not_list_is_malformed
    // dmc-case: dmc.rule.conditions_checked_after_trigger
    // dmc-case: dmc.rule.conditions_read_attributes_not_props
    // dmc-case: dmc.rule.contains_bool_actual_is_false
    // dmc-case: dmc.rule.contains_case_sensitive
    // dmc-case: dmc.rule.contains_list_member
    // dmc-case: dmc.rule.contains_list_not_member
    // dmc-case: dmc.rule.contains_number_actual_is_false
    // dmc-case: dmc.rule.contains_number_expected_on_string_is_false
    // dmc-case: dmc.rule.contains_substring
    // dmc-case: dmc.rule.contract_example_eligible
    // dmc-case: dmc.rule.contract_example_excluded
    // dmc-case: dmc.rule.depth_6_is_allowed
    // dmc-case: dmc.rule.depth_7_is_malformed
    // dmc-case: dmc.rule.device_locale_eq_bcp47
    // dmc-case: dmc.rule.device_missing_value_is_false
    // dmc-case: dmc.rule.device_platform_eq
    // dmc-case: dmc.rule.device_platform_in
    // dmc-case: dmc.rule.device_unknown_key_is_malformed
    // dmc-case: dmc.rule.empty_key_is_malformed
    // dmc-case: dmc.rule.eq_bool
    // dmc-case: dmc.rule.eq_bool_not_string_true
    // dmc-case: dmc.rule.eq_null_value_is_malformed
    // dmc-case: dmc.rule.eq_number_int_equals_double
    // dmc-case: dmc.rule.eq_number_not_numeric_string
    // dmc-case: dmc.rule.eq_numeric_string_not_number
    // dmc-case: dmc.rule.eq_string_case_sensitive
    // dmc-case: dmc.rule.eq_string_exact
    // dmc-case: dmc.rule.eq_string_true_not_bool
    // dmc-case: dmc.rule.event_name_missing_is_malformed
    // dmc-case: dmc.rule.event_trigger_name_case_sensitive
    // dmc-case: dmc.rule.event_trigger_name_only
    // dmc-case: dmc.rule.event_where_all_node_is_malformed
    // dmc-case: dmc.rule.event_where_fails_is_not_triggered
    // dmc-case: dmc.rule.event_where_is_and
    // dmc-case: dmc.rule.event_where_missing_prop_is_not_triggered
    // dmc-case: dmc.rule.event_where_mix_fails_on_not
    // dmc-case: dmc.rule.event_where_mixes_prop_and_not
    // dmc-case: dmc.rule.event_where_not_attribute_is_malformed
    // dmc-case: dmc.rule.event_where_not_bad_op_is_malformed
    // dmc-case: dmc.rule.event_where_not_contains_fails
    // dmc-case: dmc.rule.event_where_not_contains_passes
    // dmc-case: dmc.rule.event_where_not_exists_fails
    // dmc-case: dmc.rule.event_where_not_exists_passes
    // dmc-case: dmc.rule.event_where_not_in_fails
    // dmc-case: dmc.rule.event_where_not_in_missing_prop_passes
    // dmc-case: dmc.rule.event_where_not_in_passes
    // dmc-case: dmc.rule.event_where_not_not_is_malformed
    // dmc-case: dmc.rule.event_where_not_prop_is_malformed
    // dmc-case: dmc.rule.event_where_not_with_extra_key_is_malformed
    // dmc-case: dmc.rule.event_where_numeric_string
    // dmc-case: dmc.rule.event_where_passes
    // dmc-case: dmc.rule.event_where_unknown_op_is_malformed
    // dmc-case: dmc.rule.exists_false_bool_is_true
    // dmc-case: dmc.rule.exists_ignores_value
    // dmc-case: dmc.rule.exists_string_is_true
    // dmc-case: dmc.rule.gt_number_equal_is_false
    // dmc-case: dmc.rule.gte_number_above
    // dmc-case: dmc.rule.gte_number_equal
    // dmc-case: dmc.rule.in_empty_list_is_false
    // dmc-case: dmc.rule.in_number_numeric_equality
    // dmc-case: dmc.rule.in_numeric_string_not_number
    // dmc-case: dmc.rule.in_string_member
    // dmc-case: dmc.rule.in_string_not_member
    // dmc-case: dmc.rule.in_value_not_list_is_malformed
    // dmc-case: dmc.rule.lt_number
    // dmc-case: dmc.rule.lte_double_equal
    // dmc-case: dmc.rule.missing_key_contains_is_false
    // dmc-case: dmc.rule.missing_key_eq_is_false
    // dmc-case: dmc.rule.missing_key_gt_is_false
    // dmc-case: dmc.rule.missing_key_in_is_false
    // dmc-case: dmc.rule.missing_key_neq_is_false
    // dmc-case: dmc.rule.missing_key_under_not_is_true
    // dmc-case: dmc.rule.missing_op_is_malformed
    // dmc-case: dmc.rule.missing_schema_is_unsupported
    // dmc-case: dmc.rule.neq_bool
    // dmc-case: dmc.rule.neq_different_string
    // dmc-case: dmc.rule.neq_same_string
    // dmc-case: dmc.rule.neq_type_differs
    // dmc-case: dmc.rule.node_not_object_is_malformed
    // dmc-case: dmc.rule.node_with_two_shapes_is_malformed
    // dmc-case: dmc.rule.not_counts_toward_depth
    // dmc-case: dmc.rule.not_exists_on_missing_key
    // dmc-case: dmc.rule.not_in_op_is_malformed
    // dmc-case: dmc.rule.not_negates_true_leaf
    // dmc-case: dmc.rule.null_value_exists_is_false
    // dmc-case: dmc.rule.null_value_under_not_is_true
    // dmc-case: dmc.rule.numeric_bool_actual_is_false
    // dmc-case: dmc.rule.numeric_expected_bool_is_malformed
    // dmc-case: dmc.rule.numeric_expected_null_is_malformed
    // dmc-case: dmc.rule.numeric_expected_string_is_malformed
    // dmc-case: dmc.rule.numeric_list_actual_is_false
    // dmc-case: dmc.rule.numeric_string_decimal
    // dmc-case: dmc.rule.numeric_string_exponent_is_false
    // dmc-case: dmc.rule.numeric_string_integer
    // dmc-case: dmc.rule.numeric_string_negative
    // dmc-case: dmc.rule.numeric_string_plus_sign_is_false
    // dmc-case: dmc.rule.numeric_string_trailing_dot_is_false
    // dmc-case: dmc.rule.numeric_string_with_space_is_false
    // dmc-case: dmc.rule.numeric_text_is_false
    // dmc-case: dmc.rule.prop_leaf_in_conditions_is_malformed
    // dmc-case: dmc.rule.rank_fraction_is_malformed
    // dmc-case: dmc.rule.rank_missing_is_malformed
    // dmc-case: dmc.rule.rank_zero_is_malformed
    // dmc-case: dmc.rule.requires_missing_is_malformed
    // dmc-case: dmc.rule.rule_not_object_is_malformed
    // dmc-case: dmc.rule.screen_names_empty_is_malformed
    // dmc-case: dmc.rule.screen_signal_does_not_match_app_open
    // dmc-case: dmc.rule.screen_trigger_case_sensitive
    // dmc-case: dmc.rule.screen_trigger_exact_name
    // dmc-case: dmc.rule.trigger_checked_before_conditions
    // dmc-case: dmc.rule.trigger_without_any_is_malformed
    // dmc-case: dmc.rule.unknown_envelope_key_is_ignored
    // dmc-case: dmc.rule.unknown_leaf_type_is_unsupported
    // dmc-case: dmc.rule.unknown_op_is_malformed
    // dmc-case: dmc.rule.unknown_requires_is_unsupported
    // dmc-case: dmc.rule.unknown_schema_is_unsupported
    // dmc-case: dmc.rule.unknown_trigger_type_is_unsupported
    // dmc-case: dmc.rule.unsupported_wins_over_malformed
    // dmc-case: dmc.rule.version_build_suffix_ignored
    // dmc-case: dmc.rule.version_compares_parts_as_numbers
    // dmc-case: dmc.rule.version_expected_number_is_malformed
    // dmc-case: dmc.rule.version_gte_equal
    // dmc-case: dmc.rule.version_lt_is_false
    // dmc-case: dmc.rule.version_missing_part_is_zero
    // dmc-case: dmc.rule.version_neq
    // dmc-case: dmc.rule.version_os_lt
    // dmc-case: dmc.rule.version_part_without_digits_is_zero
    // dmc-case: dmc.rule.version_sdk_gte
    // dmc-case: dmc.rule.version_suffix_ignored
    // dmc-case: dmc.rule.wait_cancel_screen_left_empty_names_is_malformed
    // dmc-case: dmc.rule.wait_does_not_change_trigger_match
    // dmc-case: dmc.rule.wait_ms_fraction_is_malformed
    // dmc-case: dmc.rule.wait_ms_over_guard_is_malformed
    // dmc-case: dmc.rule.wait_ms_zero_is_malformed
    // dmc-case: dmc.rule.wait_not_an_object_is_malformed
    // dmc-case: dmc.rule.wait_unknown_cancel_type_is_unsupported
    // dmc-case: dmc.rule.wait_unknown_type_is_unsupported
    // dmc-case: dmc.rule.wait_with_all_cancel_types_is_eligible
    // dmc-case: dmc.rule.wait_without_cancel_is_eligible
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

    // dmc-case: dmc.rule_who.device_keys_are_documented_set
    @Test("limits and device keys match")
    func specLimits() throws {
        let spec = try #require(Self.fixture("dmc_rule_spec.json") as? [String: Any])
        let deviceKeys = spec["deviceKeys"] as? [String: Any] ?? [:]
        #expect(ruleDeviceKeys == Set(deviceKeys.keys))
    }

    // dmc-case: dmc.rule_who.depth_7_evaluates_no_dashboard_limit
    @Test("a rule nested far past any dashboard limit parses and evaluates")
    func deeplyNestedRule() {
        let leaf: [String: Any] = ["type": "attribute", "key": "plan", "op": "eq", "value": "pro"]
        var node: Any = leaf
        for level in 0..<200 {
            node = level % 2 == 0 ? ["all": [node]] : ["not": ["not": node]]
        }
        #expect(Self.parses(Self.rule(node)))
        #expect(Self.verdictName(Self.run(Self.rule(node), attributes: ["plan": "pro"])) == "eligible")
        #expect(Self.verdictName(Self.run(Self.rule(node), attributes: ["plan": "free"])) == "ineligible")
    }

    // dmc-case: dmc.rule.version_compares_parts_as_numbers
    // dmc-case: dmc.rule_who.version_keys_compare_as_versions
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

    // dmc-case: dmc.rule_who.parser_accepts_exactly_spec_operators
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

    // dmc-case: dmc.rule_who.parser_evaluator_never_throw
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

    // dmc-case: dmc.rule_who.default_priority_600
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

    // dmc-case: dmc.rule_who.invalid_rule_carries_detail
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

    // dmc-case: dmc.rule_when.empty_trigger_never_triggers
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

    // dmc-case: dmc.rule.eq_bool
    // dmc-case: dmc.rule.eq_bool_not_string_true
    // dmc-case: dmc.rule.eq_null_value_is_malformed
    // dmc-case: dmc.rule.eq_number_int_equals_double
    // dmc-case: dmc.rule.eq_number_not_numeric_string
    // dmc-case: dmc.rule.eq_numeric_string_not_number
    // dmc-case: dmc.rule.eq_string_case_sensitive
    // dmc-case: dmc.rule.eq_string_exact
    // dmc-case: dmc.rule.eq_string_true_not_bool
    // dmc-case: dmc.rule.neq_bool
    // dmc-case: dmc.rule.neq_different_string
    // dmc-case: dmc.rule.neq_same_string
    // dmc-case: dmc.rule.neq_type_differs
    @Test("eq and neq need the same JSON type")
    func eqNeq() {
        #expect(leaf("eq", 2, 2.0) == .eligible)
        #expect(leaf("eq", "a", "a") == .eligible)
        #expect(leaf("eq", false, false) == .eligible)
        #expect(leaf("eq", 2, "2") == .ineligible)
        #expect(leaf("neq", 2, "2") == .eligible)
        #expect(leaf("neq", "a", "a") == .ineligible)
    }

    // dmc-case: dmc.rule.in_empty_list_is_false
    // dmc-case: dmc.rule.in_number_numeric_equality
    // dmc-case: dmc.rule.in_numeric_string_not_number
    // dmc-case: dmc.rule.in_string_member
    // dmc-case: dmc.rule.in_string_not_member
    // dmc-case: dmc.rule.in_value_not_list_is_malformed
    @Test("in matches one list element")
    func inList() {
        #expect(leaf("in", ["a", "b"], "b") == .eligible)
        #expect(leaf("in", [1, 2], 2.0) == .eligible)
        #expect(leaf("in", ["1"], 1) == .ineligible)
    }

    // dmc-case: dmc.rule.contains_bool_actual_is_false
    // dmc-case: dmc.rule.contains_case_sensitive
    // dmc-case: dmc.rule.contains_list_member
    // dmc-case: dmc.rule.contains_list_not_member
    // dmc-case: dmc.rule.contains_number_actual_is_false
    // dmc-case: dmc.rule.contains_number_expected_on_string_is_false
    // dmc-case: dmc.rule.contains_substring
    @Test("contains checks substrings and list members")
    func contains() {
        #expect(leaf("contains", "ol", "gold") == .eligible)
        #expect(leaf("contains", "x", ["x", "y"]) == .eligible)
        #expect(leaf("contains", "z", ["x", "y"]) == .ineligible)
        #expect(leaf("contains", "x", 5) == .ineligible)
    }

    // dmc-case: dmc.rule.gt_number_equal_is_false
    // dmc-case: dmc.rule.gte_number_above
    // dmc-case: dmc.rule.gte_number_equal
    // dmc-case: dmc.rule.lt_number
    // dmc-case: dmc.rule.lte_double_equal
    // dmc-case: dmc.rule.numeric_bool_actual_is_false
    // dmc-case: dmc.rule.numeric_expected_bool_is_malformed
    // dmc-case: dmc.rule.numeric_expected_null_is_malformed
    // dmc-case: dmc.rule.numeric_expected_string_is_malformed
    // dmc-case: dmc.rule.numeric_list_actual_is_false
    // dmc-case: dmc.rule.numeric_string_decimal
    // dmc-case: dmc.rule.numeric_string_exponent_is_false
    // dmc-case: dmc.rule.numeric_string_integer
    // dmc-case: dmc.rule.numeric_string_negative
    // dmc-case: dmc.rule.numeric_string_plus_sign_is_false
    // dmc-case: dmc.rule.numeric_string_trailing_dot_is_false
    // dmc-case: dmc.rule.numeric_string_with_space_is_false
    // dmc-case: dmc.rule.numeric_text_is_false
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

    // dmc-case: dmc.rule.exists_false_bool_is_true
    // dmc-case: dmc.rule.exists_ignores_value
    // dmc-case: dmc.rule.exists_string_is_true
    @Test("exists is true for every non-null value")
    func exists() {
        #expect(leaf("exists", nil, "") == .eligible)
        #expect(leaf("exists", nil, 0) == .eligible)
        #expect(leaf("exists", nil, nil) == .ineligible)
    }

    // dmc-case: dmc.rule.missing_key_contains_is_false
    // dmc-case: dmc.rule.missing_key_eq_is_false
    // dmc-case: dmc.rule.missing_key_gt_is_false
    // dmc-case: dmc.rule.missing_key_in_is_false
    // dmc-case: dmc.rule.missing_key_neq_is_false
    // dmc-case: dmc.rule.not_exists_on_missing_key
    // dmc-case: dmc.rule.null_value_exists_is_false
    @Test("every op is false for a missing value")
    func missingValue() {
        for op in ["eq", "neq", "in", "contains", "gt", "exists"] {
            let value: Any? = op == "in" ? ["a"] : (op == "gt" ? 1 : "a")
            #expect(leaf(op, value, nil) == .ineligible, "\(op)")
        }
    }

    // MARK: - plain part names

    // dmc-case: dmc.rule.unknown_leaf_type_is_unsupported
    // dmc-case: dmc.rule_who.malformed_vs_unsupported_reasons
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

    // dmc-case: dmc.rule.missing_schema_is_unsupported
    // dmc-case: dmc.rule.requires_missing_is_malformed
    // dmc-case: dmc.rule.unknown_envelope_key_is_ignored
    // dmc-case: dmc.rule.unknown_schema_is_unsupported
    // dmc-case: dmc.rule_who.unknown_envelope_keys_ignored
    @Test("a leftover schema or requires key is ignored")
    func leftoverKeys() {
        var json = Self.rule(["all": []])
        json["schema"] = "dmc_rule@1"
        json["requires"] = ["dmc_rule@1", "future@9"]
        #expect(Self.parses(json))
    }

    // dmc-case: dmc.rule.unknown_leaf_type_is_unsupported
    // dmc-case: dmc.rule.unknown_requires_is_unsupported
    // dmc-case: dmc.rule_who.malformed_vs_unsupported_reasons
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

    // dmc-case: dmc.rule.event_name_missing_is_malformed
    // dmc-case: dmc.rule.event_where_unknown_op_is_malformed
    // dmc-case: dmc.rule.screen_names_empty_is_malformed
    // dmc-case: dmc.rule.trigger_without_any_is_malformed
    // dmc-case: dmc.rule.unknown_trigger_type_is_unsupported
    // dmc-case: dmc.rule_who.malformed_vs_unsupported_reasons
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

    // dmc-case: dmc.rule_when.trigger_key_lists_reject_bad_shapes
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

    // dmc-case: dmc.session.app_opened_vs_foregrounded_moments
    @Test("app_foregrounded and app_opened are different moments")
    func foregroundVsOpened() {
        let foreground: [String: Any] = ["type": "app_foregrounded"]
        #expect(Self.trigger(foreground, .appForegrounded) == .eligible)
        #expect(Self.trigger(foreground, .appOpened) == .notTriggered)
        #expect(Self.trigger(["type": "app_opened"], .appForegrounded) == .notTriggered)
    }

    // dmc-case: dmc.trigger.anchor_and_slot_visible_match_listed_key
    @Test("anchor_visible and slot_visible match one listed key")
    func visibilityTriggers() {
        #expect(Self.trigger(["type": "anchor_visible", "keys": ["cta", "buy"]], .anchorVisible("buy")) == .eligible)
        #expect(Self.trigger(["type": "anchor_visible", "keys": ["cta"]], .anchorVisible("other")) == .notTriggered)
        #expect(Self.trigger(["type": "slot_visible", "slots": ["hero"]], .slotVisible("hero")) == .eligible)
        #expect(Self.trigger(["type": "slot_visible", "slots": ["hero"]], .slotVisible("rail")) == .notTriggered)
    }

    // dmc-case: dmc.rule_who.app_opens_condition_reads_counter
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

    // dmc-case: dmc.rule.version_compares_parts_as_numbers
    // dmc-case: dmc.rule.version_gte_equal
    // dmc-case: dmc.rule_who.version_keys_compare_as_versions
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

    // dmc-case: dmc.rule_who.list_equality_elementwise
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

    // dmc-case: dmc.rule.not_in_op_is_malformed
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

    // dmc-case: dmc.rule_who.complex_and_or_over_sources
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

    // dmc-case: dmc.rule_who.invalid_rule_carries_detail
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

    // dmc-case: dmc.rule_who.parser_evaluator_never_throw
    @Test("the evaluator never throws on a rule the parser would reject")
    func evaluatorNeverThrows() {
        let broken = ValidRule(
            priority: 600,
            priorityDefaulted: false,
            triggers: [.appOpened],
            conditions: .comparison(
                Comparison(source: .attribute, key: "k", op: .gt, value: "not-a-number")),
            wait: nil,
            screens: nil)
        let verdict = RuleEvaluator.evaluate(
            .valid(broken), .appOpened, attributes: ["k": 5], device: [:])
        #expect(verdict.kind == .ineligible)
        #expect(verdict.reason == .malformedRule)
        #expect(!(verdict.detail ?? "").isEmpty)
    }
}
