import Foundation
import Testing

@testable import DigiaEngage

/// DMC `contextVariables` binding for every campaign kind. The trigger-event
/// selection cases that used to live here now run cross-stack in
/// `testkit/sdk-tests/tests/dmc/i05_*.yaml`; only the kind-specific
/// parse-and-bind coverage stays (its observable equivalents belong to the
/// guide/survey/floater YAML migrations).
@MainActor
@Suite("DMC context variables", .serialized)
struct DMCContextVariablesTests {
    // MARK: every kind binds its context variables

    private static let declaredContextVariables: [[String: Any]] = [
        ["namespace": "user", "key": "first_name", "type": "string", "fallbackValue": "friend"],
        ["namespace": "event", "key": "amount", "type": "number", "fallbackValue": "0"],
    ]

    private static var tinyCanvas: [String: Any] {
        ["version": 2, "canvasWidth": 240, "canvasHeight": 120, "children": [Any]()]
    }

    private static func withContextVariables(_ json: [String: Any], under key: String) -> [String: Any] {
        var json = json
        var block = json[key] as? [String: Any] ?? [:]
        block["contextVariables"] = declaredContextVariables
        json[key] = block
        return json
    }

    private static var floaterStoryJson: [String: Any] {
        [
            "id": "fs-id", "campaignKey": "fs", "campaignType": "floater",
            "templateConfig": [
                "templateType": "floaterStory",
                "canvas": tinyCanvas,
                "story": [
                    "pages": [["canvas": tinyCanvas]],
                    "chromeCanvas": tinyCanvas,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    @Test(
        "a Digia-fired campaign of every kind binds user and event tokens",
        arguments: ["guide", "survey", "floater", "floaterStory"])
    func everyKindBindsContextVariables(kind: String) throws {
        let json: [String: Any]
        switch kind {
        case "guide": json = Self.withContextVariables(guideJson("g"), under: "templateConfig")
        case "survey": json = Self.withContextVariables(surveyJson("s"), under: "templateConfig")
        case "floater": json = Self.withContextVariables(floaterJson("f"), under: "templateConfig")
        default: json = Self.withContextVariables(Self.floaterStoryJson, under: "templateConfig")
        }
        let campaign = try #require(try CampaignModel.fromJson(json))

        // The same call `SDKInstance.fireCampaign` makes to build the payload.
        let bound = bindContextVariables(
            campaign.variableSchemas,
            userAttributes: ["first_name": "Asha"],
            eventProperties: ["amount": 499])
        let context = buildVariableContext(schemas: campaign.variableSchemas, cepVars: bound)
        #expect(
            interpolate("How was your {{event.amount}} order, {{user.first_name}}?", context: context)
                == "How was your 499 order, Asha?")
    }
}
