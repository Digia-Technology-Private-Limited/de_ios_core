import Foundation
import Testing

@testable import DigiaEngage

private final class MissingSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []
    var records: [TimelineRecord] { lock.withLock { stored } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
}

private func context(
    namespace: String, key: String, type: String? = nil, fallback: Any? = nil
) -> VariableSchema {
    var entry: [String: Any] = ["namespace": namespace, "key": key]
    if let type { entry["type"] = type }
    if let fallback { entry["fallbackValue"] = fallback }
    return normalizeContextVariable(entry)!
}

/// Flutter: the context-variable groups of `test/variable_scope_test.dart` —
/// `normalizeContextVariable`, `bindContextVariables`, namespaced tokens and `reportMissing`.
@Suite("DMC context variable schema")
struct DMCContextVariableSchemaTests {
    private func scope(_ schemas: [VariableSchema], _ cep: [String: String]) -> VariableContext {
        buildVariableContext(schemas: schemas, cepVars: cep)
    }

    // MARK: VariableScope arithmetic via resolve

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("resolves plain identifier")
    func plainIdentifier() {
        let ctx = VariableContext(values: ["price": "100"], types: ["price": "number"])
        #expect(interpolate("Price: {{ price }}", context: ctx) == "Price: 100")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("resolves arithmetic expression")
    func arithmetic() {
        let ctx = VariableContext(values: ["price": "99"], types: ["price": "number"])
        #expect(interpolate("{{ price * 1.18 }}", context: ctx) == "116.82")
    }

    // MARK: normalizeContextVariable — parse and resolve

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("parses a user string token with a fallback")
    func parsesUserString() {
        let schema = normalizeContextVariable([
            "namespace": "user", "key": "firstName", "type": "string", "fallbackValue": "Guest",
        ])!
        #expect(schema.name == "user.firstName")
        #expect(schema.resolve("Priya") == "Priya")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("parses number and bool types")
    func parsesTypes() {
        func type(_ extra: [String: Any]) -> String? {
            normalizeContextVariable(["namespace": "event", "key": "qty"].merging(extra) { _, new in new })?.type
        }
        #expect(type([:]) == "string")
        #expect(type(["type": "number"]) == "number")
        #expect(type(["type": "bool"]) == "bool")
        #expect(type(["type": "list"]) == "string")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("accepts mixed-case keys with digits and underscores")
    func acceptsMixedCase() {
        #expect(normalizeContextVariable(["namespace": "user", "key": "Plan_2Tier", "type": "string"]) != nil)
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("rejects a missing or unusable namespace or key")
    func rejectsUnusable() {
        let entries: [[String: Any]] = [
            ["key": "qty"],
            ["namespace": "device", "key": "qty"],
            ["namespace": "event"],
            ["namespace": "event", "key": 2],
            ["namespace": "event", "key": "2qty"],
            ["namespace": "event", "key": "a.b"],
            ["namespace": "event", "key": ""],
        ]
        for entry in entries { #expect(normalizeContextVariable(entry) == nil, "\(entry)") }
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("runtime value wins over fallback")
    func runtimeWins() {
        let schema = context(namespace: "event", key: "qty", type: "number", fallback: "9")
        #expect(schema.resolve(42) == "42")
        #expect(schema.resolve(0) == "0")
        #expect(schema.resolve(199.0) == "199")
        #expect(schema.resolve("2.50") == "2.5")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("a value that does not fit the type falls through to the fallback")
    func misfitFallsThrough() {
        let qty = context(namespace: "event", key: "qty", type: "number", fallback: "9")
        #expect(qty.resolve("abc") == "9")
        #expect(qty.resolve(false) == "9")
        let vip = context(namespace: "event", key: "vip", type: "bool", fallback: "false")
        #expect(vip.resolve("TRUE") == "true")
        #expect(vip.resolve("yes") == "false")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("a missing or unknown type is inferred from a typed fallback")
    func typeInferred() {
        func parse(_ extra: [String: Any]) -> VariableSchema {
            normalizeContextVariable(["namespace": "event", "key": "k"].merging(extra) { _, new in new })!
        }
        #expect(parse(["fallbackValue": 3]).type == "number")
        #expect(parse(["type": "integer", "fallbackValue": 3]).type == "number")
        #expect(parse(["fallbackValue": true]).type == "bool")
        #expect(parse(["fallbackValue": "3"]).type == "string")
        #expect(parse(["fallbackValue": 3]).resolve(4.0) == "4")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("empty runtime falls through to fallback")
    func emptyRuntime() {
        let schema = context(namespace: "user", key: "city", fallback: "Mumbai")
        #expect(schema.resolve(nil) == "Mumbai")
        #expect(schema.resolve("") == "Mumbai")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("no value and no fallback yields the type default")
    func typeDefault() {
        #expect(context(namespace: "user", key: "city").resolve(nil) == "")
        #expect(context(namespace: "event", key: "qty", type: "number").resolve(nil) == "0")
        #expect(context(namespace: "event", key: "vip", type: "bool").resolve(nil) == "false")
    }

    // MARK: bindContextVariables

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("no declared tokens yields an empty map")
    func bindNone() {
        #expect(bindContextVariables([], userAttributes: ["city": "Pune"]).isEmpty)
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("resolves user and event tokens from their sources")
    func bindSources() {
        let resolved = bindContextVariables(
            [
                context(namespace: "user", key: "firstName"),
                context(namespace: "user", key: "city", fallback: "Pune"),
                context(namespace: "event", key: "qty", type: "number"),
            ],
            userAttributes: ["firstName": "Priya", "city": ""],
            eventProperties: ["qty": 3])
        #expect(resolved == ["user.firstName": "Priya", "user.city": "Pune", "event.qty": "3"])
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("a missing event property falls back, then to the type default")
    func bindMissingEvent() {
        let resolved = bindContextVariables(
            [
                context(namespace: "event", key: "coupon", fallback: "SAVE10"),
                context(namespace: "event", key: "qty", type: "number"),
                context(namespace: "event", key: "vip", type: "bool"),
            ],
            userAttributes: [:], eventProperties: [:])
        #expect(resolved == ["event.coupon": "SAVE10", "event.qty": "0", "event.vip": "false"])
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("an event token with no properties resolves to its fallback")
    func bindNoProperties() {
        let resolved = bindContextVariables(
            [context(namespace: "event", key: "qty", fallback: "1")], userAttributes: [:])
        #expect(resolved["event.qty"] == "1")
    }

    // MARK: namespaced tokens

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("resolves user. and event. tokens from the variable map")
    func namespacedFromMap() {
        let vars = ["user.firstName": "Priya", "event.qty": "3"]
        #expect(interpolate("{{ user.firstName }}", variables: vars) == "Priya")
        #expect(interpolate("Qty {{ event.qty }}", variables: vars) == "Qty 3")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("mixes namespaced and custom tokens")
    func mixesTokens() {
        let ctx = VariableContext(
            values: ["user.firstName": "Priya", "coupon": "SAVE10"], types: ["coupon": "string"])
        #expect(interpolate("{{ user.firstName }}, {{ coupon }}", context: ctx) == "Priya, SAVE10")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("a missing namespaced token collapses to empty")
    func missingNamespaced() {
        #expect(interpolate("{{ user.firstName }}", context: .empty) == "")
        #expect(interpolate("{{ event.qty }}", context: .empty) == "")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("fromSchemas resolves only declared tokens, custom or context")
    func declaredOnly() {
        let ctx = scope(
            [
                VariableSchema(name: "coupon", type: "string", fallbackValue: ""),
                context(namespace: "user", key: "firstName"),
            ],
            ["coupon": "SAVE10", "user.firstName": "Priya", "event.qty": "3", "undeclared": "dropped"])
        #expect(interpolate("{{ user.firstName }}", context: ctx) == "Priya")
        #expect(interpolate("{{ coupon }}", context: ctx) == "SAVE10")
        #expect(interpolate("{{ event.qty }}", context: ctx) == "")
        #expect(interpolate("{{ undeclared }}", context: ctx) == "")
    }

    // MARK: user and event tokens behave like custom variables

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("a number user or event token takes part in arithmetic")
    func numberTokensArithmetic() {
        let ctx = scope(
            [
                context(namespace: "user", key: "age", type: "number"),
                context(namespace: "event", key: "orderValue", type: "number"),
                VariableSchema(name: "bonus", type: "number", fallbackValue: "5"),
            ],
            ["user.age": "30", "event.orderValue": "199.0"])
        #expect(interpolate("{{ user.age + 1 }}", context: ctx) == "31")
        #expect(interpolate("{{ event.orderValue * 2 + bonus }}", context: ctx) == "403")
    }

    // dmc-case: dmc.context_vars.schema_parse_bind_fallback
    @Test("a string token is not a number operand")
    func stringNotOperand() {
        let ctx = scope([context(namespace: "user", key: "name")], ["user.name": "Priya"])
        #expect(interpolate("{{ user.name + 1 }}", context: ctx) == "")
    }

    // MARK: reportMissing

    private func reported(_ schema: VariableSchema, _ cep: [String: String]) -> Bool {
        let sink = MissingSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        reportMissingVariables(
            [schema], payload: CEPTriggerPayload(cepCampaignId: "c", campaignKey: "campaign", cepMetadata: [:], variables: cep))
        return sink.records.contains { $0.reason?.wire == TimelineReason.missingVariable.wire }
    }

    // dmc-case: dmc.context_vars.empty_and_sample_report_rules
    @Test("sampleValue only does not report")
    func sampleOnlyNoReport() {
        #expect(!reported(normalizeVariable(name: "name", type: nil, fallbackValue: nil, sampleValue: "Sam"), [:]))
    }

    // dmc-case: dmc.context_vars.empty_and_sample_report_rules
    @Test("CEP empty string with no fallback reports")
    func emptyNoFallbackReports() {
        #expect(reported(normalizeVariable(name: "name", type: nil, fallbackValue: nil, sampleValue: nil), ["name": ""]))
    }

    // dmc-case: dmc.context_vars.empty_and_sample_report_rules
    @Test("empty fallbackValue does not report")
    func emptyFallbackNoReport() {
        #expect(!reported(normalizeVariable(name: "name", type: nil, fallbackValue: "", sampleValue: nil), [:]))
    }

    // MARK: typed CEP values and the variable_type_mismatch health event

    private func slot(_ name: String, _ type: String, _ fallback: String = "FB") -> VariableSchema {
        VariableSchema(name: name, type: type, fallbackValue: fallback)
    }

    private var mismatchSchemas: [VariableSchema] {
        [
            slot("s_num", "string"), slot("s_bool", "string"), slot("s_text", "string"),
            slot("n_int", "number", "7"), slot("n_pad", "number", "7"), slot("n_sym", "number", "7"),
            slot("n_comma", "number", "7"), slot("n_bool", "number", "7"), slot("n_long", "number", "7"),
            slot("b_upper", "bool", "false"), slot("b_false", "bool", "true"), slot("b_yes", "bool", "false"), slot("b_one", "bool", "false"),
            slot("price", "number", "999"),
        ]
    }

    // CEP payload values reach iOS as strings.
    private let mismatchCep: [String: String] = [
        "s_num": "499", "s_bool": "true", "s_text": "₹499",
        "n_int": "499", "n_pad": " 499.00 ", "n_sym": "₹499", "n_comma": "1,299",
        "n_bool": "true", "n_long": String(repeating: "x", count: 40),
        "b_upper": "TRUE", "b_false": "false", "b_yes": "yes", "b_one": "1",
        "price": "₹499",
    ]

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [HealthEventPayload] = []
        var payloads: [HealthEventPayload] { lock.withLock { stored } }
        func capture(_ payload: HealthEventPayload) { lock.withLock { stored.append(payload) } }
    }

    private func activatedSink() -> (HealthSink, Recorder) {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.beginPending()
        sink.activate { recorder.capture($0) }
        return (sink, recorder)
    }

    private func report(_ cep: [String: String], _ sink: HealthSink, campaign: String = "cmp_123") {
        reportVariableTypeMismatches(
            mismatchSchemas,
            payload: CEPTriggerPayload(cepCampaignId: "c", campaignKey: campaign, cepMetadata: [:], variables: cep),
            sink: sink)
    }

    @Test("each slot shows its converted value or its fallback")
    func typedSlotsRender() {
        let ctx = scope(mismatchSchemas, mismatchCep)
        func r(_ name: String) -> String { interpolate("{{ \(name) }}", context: ctx) }
        #expect([r("s_num"), r("s_bool"), r("s_text")] == ["499", "true", "₹499"])
        #expect([r("n_int"), r("n_pad")] == ["499", "499"])
        #expect([r("n_sym"), r("n_comma"), r("n_bool"), r("n_long")] == Array(repeating: "7", count: 4))
        #expect([r("b_upper"), r("b_false")] == ["true", "false"])
        #expect([r("b_yes"), r("b_one")] == ["false", "false"])
        #expect(interpolate("{{ price * 2 }}", context: ctx) == "1998")
    }

    @Test("one event per campaign names only the failed variables")
    func oneEventNamesFailures() {
        let (sink, recorder) = activatedSink()
        report(mismatchCep, sink)
        report(mismatchCep, sink)

        #expect(recorder.payloads.count == 1)
        let payload = recorder.payloads[0]
        #expect(payload.campaignKey == "cmp_123")
        #expect(payload.reason == "variable_type_mismatch")
        let mismatches = payload.mismatches ?? []
        #expect(mismatches.map { $0["name"] } == ["n_sym", "n_comma", "n_bool", "n_long", "b_yes", "b_one", "price"])
        #expect(mismatches[0] == ["name": "n_sym", "expected": "number", "sample": "₹499"])
        #expect(mismatches[3]["sample"] == String(repeating: "x", count: 16) + "\u{2026}" + String(repeating: "x", count: 15))
    }

    /// The same table runs in the Android and Flutter tests: every stack must agree.
    static let variableSampleCases: [(name: String, input: String, expected: String)] = [
        ("empty", "", ""),
        ("short_non_ascii", "\u{20B9}499", "\u{20B9}499"),
        ("ascii_exactly_32", "abcdefghijklmnopqrstuvwxyz012345", "abcdefghijklmnopqrstuvwxyz012345"),
        ("ascii_33", "abcdefghijklmnopqrstuvwxyz0123456", "abcdefghijklmnop\u{2026}stuvwxyz0123456"),
        ("ascii_long", "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789", "abcdefghijklmnop\u{2026}vwxyz0123456789"),
        ("emoji_exactly_32", "\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}", "\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}"),
        ("emoji_33", "\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}", "\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{2026}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}"),
        ("emoji_at_head_cut", "aaaaaaaaaaaaaaa\u{1F600}bbbbbbbbbbbbbbbbbbbb", "aaaaaaaaaaaaaaa\u{1F600}\u{2026}bbbbbbbbbbbbbbb"),
        ("emoji_at_tail_cut", "aaaaaaaaaaaaaaaaaaaa\u{1F600}bbbbbbbbbbbbbb", "aaaaaaaaaaaaaaaa\u{2026}\u{1F600}bbbbbbbbbbbbbb"),
        ("combining_at_head_cut", "aaaaaaaaaaaaaaae\u{301}bbbbbbbbbbbbbbbbbbbb", "aaaaaaaaaaaaaaa\u{2026}bbbbbbbbbbbbbbb"),
        ("combining_at_tail_start", "aaaaaaaaaaaaaaaaaaae\u{301}bbbbbbbbbbbbbb", "aaaaaaaaaaaaaaaa\u{2026}bbbbbbbbbbbbbb"),
        ("combining_exactly_32_cps", "aaaaaaaaaaaaaaaae\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}", "aaaaaaaaaaaaaaaae\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}"),
        ("combining_many_marks", "aaaaaaaaaaaaaaae\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}", "aaaaaaaaaaaaaaa\u{2026}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}"),
    ]

    @Test("a long sample is shortened with a middle ellipsis, identically on every stack",
          arguments: variableSampleCases.map { $0.name })
    func samplesShortenedWithMiddleEllipsis(name: String) throws {
        let c = try #require(Self.variableSampleCases.first { $0.name == name })
        #expect(Array(truncatedMismatchSample(c.input).unicodeScalars) == Array(c.expected.unicodeScalars))
    }

    @Test("a different failing variable later sends a new event")
    func newVariableNewEvent() {
        let (sink, recorder) = activatedSink()
        report(mismatchCep, sink)
        report(mismatchCep.merging(["n_int": "abc"]) { _, new in new }, sink)
        #expect(recorder.payloads.count == 2)
    }

    @Test("at most 10 entries")
    func capsEntries() {
        let (sink, recorder) = activatedSink()
        let many = (0..<12).map { slot("v\($0)", "number") }
        reportVariableTypeMismatches(
            many,
            payload: CEPTriggerPayload(
                cepCampaignId: "c", campaignKey: "cmp_9", cepMetadata: [:],
                variables: Dictionary(uniqueKeysWithValues: many.map { ($0.name, "bad") })),
            sink: sink)
        #expect(recorder.payloads.first?.mismatches?.count == 10)
    }
}
