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

    @Test("resolves plain identifier")
    func plainIdentifier() {
        let ctx = VariableContext(values: ["price": "100"], types: ["price": "number"])
        #expect(interpolate("Price: {{ price }}", context: ctx) == "Price: 100")
    }

    @Test("resolves arithmetic expression")
    func arithmetic() {
        let ctx = VariableContext(values: ["price": "99"], types: ["price": "number"])
        #expect(interpolate("{{ price * 1.18 }}", context: ctx) == "116.82")
    }

    // MARK: normalizeContextVariable — parse and resolve

    @Test("parses a user string token with a fallback")
    func parsesUserString() {
        let schema = normalizeContextVariable([
            "namespace": "user", "key": "firstName", "type": "string", "fallbackValue": "Guest",
        ])!
        #expect(schema.name == "user.firstName")
        #expect(schema.resolve("Priya") == "Priya")
    }

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

    @Test("accepts mixed-case keys with digits and underscores")
    func acceptsMixedCase() {
        #expect(normalizeContextVariable(["namespace": "user", "key": "Plan_2Tier", "type": "string"]) != nil)
    }

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

    @Test("runtime value wins over fallback")
    func runtimeWins() {
        let schema = context(namespace: "event", key: "qty", type: "number", fallback: "9")
        #expect(schema.resolve(42) == "42")
        #expect(schema.resolve(0) == "0")
        #expect(schema.resolve(199.0) == "199")
        #expect(schema.resolve("2.50") == "2.5")
    }

    @Test("a value that does not fit the type falls through to the fallback")
    func misfitFallsThrough() {
        let qty = context(namespace: "event", key: "qty", type: "number", fallback: "9")
        #expect(qty.resolve("abc") == "9")
        #expect(qty.resolve(false) == "9")
        let vip = context(namespace: "event", key: "vip", type: "bool", fallback: "false")
        #expect(vip.resolve("TRUE") == "true")
        #expect(vip.resolve("yes") == "false")
    }

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

    @Test("empty runtime falls through to fallback")
    func emptyRuntime() {
        let schema = context(namespace: "user", key: "city", fallback: "Mumbai")
        #expect(schema.resolve(nil) == "Mumbai")
        #expect(schema.resolve("") == "Mumbai")
    }

    @Test("no value and no fallback yields the type default")
    func typeDefault() {
        #expect(context(namespace: "user", key: "city").resolve(nil) == "")
        #expect(context(namespace: "event", key: "qty", type: "number").resolve(nil) == "0")
        #expect(context(namespace: "event", key: "vip", type: "bool").resolve(nil) == "false")
    }

    // MARK: bindContextVariables

    @Test("no declared tokens yields an empty map")
    func bindNone() {
        #expect(bindContextVariables([], userAttributes: ["city": "Pune"]).isEmpty)
    }

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

    @Test("an event token with no properties resolves to its fallback")
    func bindNoProperties() {
        let resolved = bindContextVariables(
            [context(namespace: "event", key: "qty", fallback: "1")], userAttributes: [:])
        #expect(resolved["event.qty"] == "1")
    }

    // MARK: namespaced tokens

    @Test("resolves user. and event. tokens from the variable map")
    func namespacedFromMap() {
        let vars = ["user.firstName": "Priya", "event.qty": "3"]
        #expect(interpolate("{{ user.firstName }}", variables: vars) == "Priya")
        #expect(interpolate("Qty {{ event.qty }}", variables: vars) == "Qty 3")
    }

    @Test("mixes namespaced and custom tokens")
    func mixesTokens() {
        let ctx = VariableContext(
            values: ["user.firstName": "Priya", "coupon": "SAVE10"], types: ["coupon": "string"])
        #expect(interpolate("{{ user.firstName }}, {{ coupon }}", context: ctx) == "Priya, SAVE10")
    }

    @Test("a missing namespaced token collapses to empty")
    func missingNamespaced() {
        #expect(interpolate("{{ user.firstName }}", context: .empty) == "")
        #expect(interpolate("{{ event.qty }}", context: .empty) == "")
    }

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

    @Test("sampleValue only does not report")
    func sampleOnlyNoReport() {
        #expect(!reported(normalizeVariable(name: "name", type: nil, fallbackValue: nil, sampleValue: "Sam"), [:]))
    }

    @Test("CEP empty string with no fallback reports")
    func emptyNoFallbackReports() {
        #expect(reported(normalizeVariable(name: "name", type: nil, fallbackValue: nil, sampleValue: nil), ["name": ""]))
    }

    @Test("empty fallbackValue does not report")
    func emptyFallbackNoReport() {
        #expect(!reported(normalizeVariable(name: "name", type: nil, fallbackValue: "", sampleValue: nil), [:]))
    }
}
