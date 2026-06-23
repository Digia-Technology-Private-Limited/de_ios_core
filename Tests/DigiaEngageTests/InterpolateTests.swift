import Foundation
@testable import DigiaEngage
import Testing

// Tests parity with expr-test-vectors.json (shared across all surfaces).

@Suite("Interpolate")
struct InterpolateTests {

    // MARK: - Helpers

    private func schema(_ name: String, type t: String = "string", fallback: String = "") -> VariableSchema {
        VariableSchema(name: name, type: t, fallbackValue: fallback)
    }

    private func context(_ schemas: [VariableSchema], cep: [String: String]? = nil) -> VariableContext {
        buildVariableContext(schemas: schemas, cepVars: cep)
    }

    private func eval(_ expr: String, schemas: [VariableSchema], cep: [String: String]? = nil) -> String {
        let ctx = context(schemas, cep: cep)
        return interpolate("{{\(expr)}}", context: ctx)
    }

    // MARK: - D29: normalizeVariable

    @Test("absent type defaults to string")
    func normalizeAbsentType() {
        let s = normalizeVariable(name: "x", type: nil, fallbackValue: "42", sampleValue: nil)
        #expect(s.type == "string")
    }

    @Test("sampleValue used when fallbackValue absent")
    func normalizeSampleValueFallback() {
        let s = normalizeVariable(name: "x", type: "number", fallbackValue: nil, sampleValue: "7")
        #expect(s.fallbackValue == "7")
    }

    @Test("fallbackValue wins over sampleValue")
    func normalizeFallbackValueWins() {
        let s = normalizeVariable(name: "x", type: "string", fallbackValue: "fb", sampleValue: "sv")
        #expect(s.fallbackValue == "fb")
    }

    // MARK: - D3′: buildVariableContext

    @Test("CEP value wins over fallback")
    func cepValueWins() {
        let ctx = context([schema("name", type: "string", fallback: "Default")], cep: ["name": "Alex"])
        #expect(ctx.values["name"] == "Alex")
    }

    @Test("empty CEP value falls through to fallback")
    func emptyCepFallsThrough() {
        let ctx = context([schema("name", type: "string", fallback: "Anon")], cep: ["name": ""])
        #expect(ctx.values["name"] == "Anon")
    }

    @Test("absent CEP value falls through to fallback")
    func absentCepFallsThrough() {
        let ctx = context([schema("name", type: "string", fallback: "Anon")], cep: nil)
        #expect(ctx.values["name"] == "Anon")
    }

    @Test("no CEP and no fallback gives empty string")
    func noCepNoFallback() {
        let ctx = context([schema("name")], cep: nil)
        #expect(ctx.values["name"] == "")
    }

    @Test("type is carried into context")
    func typeInContext() {
        let ctx = context([schema("price", type: "number", fallback: "0")], cep: ["price": "99"])
        #expect(ctx.types["price"] == "number")
    }

    // MARK: - Plain substitution

    @Test("plain string var from CEP")
    func plainStringVar() {
        let result = eval("name", schemas: [schema("name", type: "string")], cep: ["name": "Alex"])
        #expect(result == "Alex")
    }

    @Test("plain var — empty CEP falls through to fallback")
    func plainVarFallback() {
        let result = eval("name", schemas: [schema("name", fallback: "Anon")], cep: ["name": ""])
        #expect(result == "Anon")
    }

    @Test("plain var — no CEP and no fallback gives empty string")
    func plainVarEmpty() {
        let result = eval("name", schemas: [schema("name")], cep: nil)
        #expect(result == "")
    }

    // MARK: - BODMAS / arithmetic

    @Test("BODMAS: a + b*c = a + (b*c)")
    func bodmasAddMul() {
        let schemas = [schema("a", type: "number"), schema("b", type: "number"), schema("c", type: "number")]
        let result = eval("a + b*c", schemas: schemas, cep: ["a": "2", "b": "3", "c": "4"])
        #expect(result == "14")
    }

    @Test("BODMAS: a*b + c = (a*b) + c")
    func bodmasMulAdd() {
        let schemas = [schema("a", type: "number"), schema("b", type: "number"), schema("c", type: "number")]
        let result = eval("a*b + c", schemas: schemas, cep: ["a": "2", "b": "3", "c": "4"])
        #expect(result == "10")
    }

    @Test("decimal mul rounds to 4 dp, strip trailing zeros")
    func decimalMulRounded() {
        let result = eval("price * 1.18", schemas: [schema("price", type: "number")], cep: ["price": "99"])
        #expect(result == "116.82")
    }

    @Test("10 / 3 rounds to 4 dp")
    func divisionRounded() {
        let result = eval("10 / 3", schemas: [], cep: nil)
        #expect(result == "3.3333")
    }

    @Test("exact division strips trailing zeros")
    func divisionExact() {
        let result = eval("4 / 2", schemas: [], cep: nil)
        #expect(result == "2")
    }

    @Test("0.1 + 0.2 rounds to 0.3")
    func floatingPoint() {
        let result = eval("0.1 + 0.2", schemas: [], cep: nil)
        #expect(result == "0.3")
    }

    @Test("unary minus on variable")
    func unaryMinusVar() {
        let schemas = [schema("a", type: "number"), schema("b", type: "number")]
        let result = eval("-a + b", schemas: schemas, cep: ["a": "5", "b": "8"])
        #expect(result == "3")
    }

    @Test("unary minus on literal")
    func unaryMinusLiteral() {
        let result = eval("a * -2", schemas: [schema("a", type: "number")], cep: ["a": "5"])
        #expect(result == "-10")
    }

    @Test("division by zero — empty string")
    func divisionByZero() {
        let schemas = [schema("a", type: "number"), schema("b", type: "number")]
        let result = eval("a / b", schemas: schemas, cep: ["a": "5", "b": "0"])
        #expect(result == "")
    }

    @Test("non-numeric CEP value in arithmetic — empty string")
    func nonNumericCep() {
        let schemas = [schema("a", type: "number"), schema("b", type: "number")]
        let result = eval("a + b", schemas: schemas, cep: ["a": "x", "b": "2"])
        #expect(result == "")
    }

    @Test("variable missing from schema — empty string")
    func missingVar() {
        let result = eval("a + b", schemas: [schema("a", type: "number")], cep: ["a": "2"])
        #expect(result == "")
    }

    // MARK: - Identifier grammar (D22′: lowercase only)

    @Test("uppercase identifier is not substituted")
    func uppercaseIdentifier() {
        let ctx = VariableContext(values: ["Name": "Alex"], types: ["Name": "string"])
        let result = interpolate("{{Name}}", context: ctx)
        #expect(result == "")
    }

    @Test("underscore prefix identifier is not substituted")
    func underscorePrefixIdentifier() {
        let ctx = VariableContext(values: ["_name": "Alex"], types: ["_name": "string"])
        let result = interpolate("{{_name}}", context: ctx)
        #expect(result == "")
    }

    // MARK: - Multi-placeholder interpolation

    @Test("multiple placeholders in one string")
    func multiplePlaceholders() {
        let schemas = [schema("first", fallback: ""), schema("last", fallback: "")]
        let ctx = context(schemas, cep: ["first": "Ada", "last": "Lovelace"])
        let result = interpolate("Hello, {{first}} {{last}}!", context: ctx)
        #expect(result == "Hello, Ada Lovelace!")
    }

    @Test("mixed plain and arithmetic placeholders")
    func mixedPlaceholders() {
        let schemas = [
            schema("name", type: "string"),
            schema("price", type: "number"),
        ]
        let ctx = context(schemas, cep: ["name": "Priya", "price": "100"])
        let result = interpolate("Hi {{name}}, your total is {{price * 1.18}}", context: ctx)
        #expect(result == "Hi Priya, your total is 118")
    }

    // MARK: - No-op when no placeholders

    @Test("string without placeholders is returned as-is")
    func noPlaceholders() {
        let result = interpolate("Hello, world!", context: nil)
        #expect(result == "Hello, world!")
    }

    // MARK: - Backward-compat shim

    @Test("flat variable shim substitutes correctly")
    func flatVariableShim() {
        let result = interpolate("Hello {{name}}", variables: ["name": "World"])
        #expect(result == "Hello World")
    }
}
