import Foundation
import Testing

@testable import DigiaEngage

/// The SDK resolves `{{ }}` tokens before `init` is built, so the skin only ever reads
/// finished text. Mirrors Android's `GameVariablesTest`.
struct GameVariablesTests {
    private let context = buildVariableContext(
        schemas: [
            VariableSchema(name: "user", type: "string", fallbackValue: "there"),
            VariableSchema(name: "prize", type: "string", fallbackValue: "a gift"),
        ],
        cepVars: ["user": "Aditya"])

    // Fails if a string leaf stops resolving, including through nested objects and
    // arrays, if a non-string value is rewritten, or if the CEP value stops winning
    // over the fallback: the `.string`, `.object` and `.array` arms of `resolveGameValue`.
    @Test func everyStringLeafResolvesAndOtherValuesPassThrough() {
        let out = resolveGameValues(
            [
                "titleText": .string("Hi, {{user}}"),
                "primaryColor": .string("#fff"),
                "n": .int(3),
                "nested": .object(["label": .string("For {{user}}")]),
                "list": .array([.string("{{prize}}")]),
            ],
            context: context)
        #expect(out["titleText"] == .string("Hi, Aditya"))
        #expect(out["primaryColor"] == .string("#fff"))
        #expect(out["n"] == .int(3))
        #expect(out["nested"] == .object(["label": .string("For Aditya")]))
        #expect(out["list"] == .array([.string("a gift")]))
    }

    // Fails if slot values stop resolving, or a slot loses its `outcomeKey`: the
    // `resolveGameValues($0.values, ...)` call in `resolveGameSlots`.
    @Test func slotValuesResolveWithTheirOutcomeKeyKept() {
        let slots = resolveGameSlots(
            [GamificationSlotConfig(outcomeKey: "o1", values: ["label": .string("Win {{prize}}")])],
            context: context)
        #expect(slots.map(\.outcomeKey) == ["o1"])
        #expect(slots.first?.values["label"] == .string("Win a gift"))
    }

    // Fails if an undeclared token starts reaching the skin as raw text: the
    // `context?.values[inner] ?? ""` line in `interpolate`.
    @Test func undeclaredTokenResolvesToEmpty() {
        let out = resolveGameValues(["t": .string("Hi, {{nope}}")], context: context)
        #expect(out["t"] == .string("Hi, "))
    }

    // Fails if the open stops handing resolved values and slots to the skin: the
    // `resolveGameValues` / `resolveGameSlots` arguments in `makeGameOpenRequest`.
    @MainActor
    @Test func openRequestCarriesResolvedValuesAndSlots() async throws {
        let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
        let sdk = SDKInstance(
            defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() })
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
        let config = try #require(GamificationConfig.fromJson([
            "skinId": "wheel", "skinVersion": 2,
            "bundleUrl": "https://cdn.example.com/skins/wheel/2/index.html",
            "config": [
                "values": ["titleText": "Hi, {{user}}"],
                "slots": [["outcomeKey": "o1", "values": ["label": "Win {{prize}}"]]],
            ] as [String: Any],
        ]))
        var campaign = CampaignModel(
            id: "camp-1", campaignKey: "bill_pay_spin", campaignType: "gamification",
            config: .gamification(config), targetScreenNames: [])
        campaign.variableSchemas = [
            VariableSchema(name: "user", type: "string", fallbackValue: "there"),
            VariableSchema(name: "prize", type: "string", fallbackValue: "a gift"),
        ]
        let payload = CEPTriggerPayload(
            cepCampaignId: "msg-1", campaignKey: "bill_pay_spin", cepMetadata: [:],
            variables: ["user": "Aditya"])
        let request = sdk.gameSurface.makeGameOpenRequest(
            file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("index.html"),
            chanceId: "ch-1", config: config, campaign: campaign, payload: payload,
            userId: "u_123", settle: .presentation(payload: payload, entry: .direct))
        #expect(request.values["titleText"] == .string("Hi, Aditya"))
        #expect(request.slots.map(\.outcomeKey) == ["o1"])
        #expect(request.slots.first?.values["label"] == .string("Win a gift"))
    }

    // Fails if a floating entry stops reading the campaign's declarations: `variables`
    // missing from the keys `parseEntryCanvas` copies onto the teaser.
    @Test func floatingEntryKeepsTheCampaignVariables() throws {
        let config = try #require(GamificationConfig.fromJson([
            "skinId": "wheel", "skinVersion": 2,
            "bundleUrl": "https://cdn.example.com/skins/wheel/2/index.html",
            "entry": ["kind": "floating"],
            "variables": [["name": "user", "type": "string", "fallbackValue": "there"]]
                as [[String: Any]],
            "teaser": [
                "canvas": [
                    "version": 2, "canvasWidth": 320, "canvasHeight": 200, "children": [Any](),
                ] as [String: Any],
            ],
        ]))
        guard case .floating(let entry)? = config.entryCanvas else {
            Issue.record("the floating teaser did not parse")
            return
        }
        #expect(entry.variableSchemas.map(\.name) == ["user"])
        #expect(entry.variableSchemas.first?.fallbackValue == "there")
    }
}
