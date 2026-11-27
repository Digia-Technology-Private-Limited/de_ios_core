import Foundation
import Testing

@testable import DigiaEngage

/// The SDK resolves `{{ }}` tokens before `init`, so the skin only ever gets finished text.
struct GameVariablesTests {
    private let context = buildVariableContext(
        schemas: [
            VariableSchema(name: "user", type: "string", fallbackValue: "there"),
            VariableSchema(name: "prize", type: "string", fallbackValue: "a gift"),
        ],
        cepVars: ["user": "Aditya"])

    @Test func tokensResolveInValuesAndSlotsWithFallbackForMissingPayload() {
        let out = resolveGameValues(
            ["titleText": .string("Hi, {{user}}"), "primaryColor": .string("#fff"), "n": .int(3)],
            context: context)
        #expect(out["titleText"] == .string("Hi, Aditya"))
        #expect(out["primaryColor"] == .string("#fff"))
        #expect(out["n"] == .int(3))

        let slots = resolveGameSlots(
            [GamificationSlotConfig(outcomeKey: "o1", values: ["label": .string("Win {{prize}}")])],
            context: context)
        #expect(slots.first?.values["label"] == .string("Win a gift"))
        #expect(slots.first?.outcomeKey == "o1")
    }

    @Test func undeclaredTokenResolvesToEmpty() {
        let out = resolveGameValues(["t": .string("Hi, {{nope}}")], context: context)
        #expect(out["t"] == .string("Hi, "))
    }
}
