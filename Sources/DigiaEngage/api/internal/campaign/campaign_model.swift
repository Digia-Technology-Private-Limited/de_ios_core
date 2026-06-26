import Foundation

// Ported from Android `CampaignModel.kt`. Survey campaigns are delivered as the
// campaign's `surveyConfig` (or a `templateConfig` with `templateType ==
// "survey"`) and parsed into a `SurveyConfigModel`, mirroring Android.

enum CampaignConfigModel: Equatable {
    case guide(GuideConfigModel)
    case nudge(NudgeConfig)
    case inline(InlineCarouselConfig)
    case story(InlineStoryConfig)
    case survey(SurveyConfigModel)
}

struct CampaignModel: Equatable {
    let id: String
    let campaignKey: String
    let campaignType: String
    let config: CampaignConfigModel
    // Opaque capping policy from the dashboard; nil = "No cap" / inline.
    // Used natively for nudge + survey only (guides cap in JS on RN).
    var frequency: FrequencyPolicy? = nil

    var guideConfig: GuideConfigModel? {
        if case let .guide(value) = config { return value }
        return nil
    }

    var storyConfig: InlineStoryConfig? {
        if case let .story(value) = config { return value }
        return nil
    }

    var nudgeConfig: NudgeConfig? {
        if case let .nudge(value) = config { return value }
        return nil
    }

    var surveyConfig: SurveyConfigModel? {
        if case let .survey(value) = config { return value }
        return nil
    }

    static func fromJson(_ json: [String: Any]) -> CampaignModel? {
        guard let id = json.nonBlankString("id") ?? json.nonBlankString("_id") else { return nil }
        guard let campaignKey = json.nonBlankString("campaignKey") else { return nil }
        guard let campaignType = json.nonBlankString("campaignType") else { return nil }

        let config: CampaignConfigModel
        switch campaignType {
        case "guide":
            guard let guideConfig = parseGuideConfig(json, fallbackId: id) else { return nil }
            config = .guide(guideConfig)
        case "nudge":
            guard let templateConfig = json.object("templateConfig"),
                  let nudgeConfig = NudgeConfig.fromJson(templateConfig) else { return nil }
            config = .nudge(nudgeConfig)
        case "inline":
            guard let templateConfig = json.object("templateConfig") else { return nil }
            switch templateConfig.string("templateType", default: "carousel") {
            case "story":
                guard let storyConfig = InlineStoryConfig.fromJson(templateConfig) else { return nil }
                config = .story(storyConfig)
            default:
                guard let carouselConfig = InlineCarouselConfig.fromJson(templateConfig) else { return nil }
                config = .inline(carouselConfig)
            }
        case "survey":
            guard let surveyConfig = parseSurveyConfig(json, fallbackId: id) else { return nil }
            config = .survey(surveyConfig)
        default:
            // Any unknown type is skipped.
            return nil
        }

        return CampaignModel(
            id: id,
            campaignKey: campaignKey,
            campaignType: campaignType,
            config: config,
            frequency: FrequencyPolicy.fromJson(json.object("frequency"))
        )
    }

    // ── survey parsing ────────────────────────────────────────────────────────

    private static func parseSurveyConfig(_ json: [String: Any], fallbackId: String) -> SurveyConfigModel? {
        let raw: [String: Any]?
        if let survey = json["surveyConfig"] as? [String: Any] {
            raw = survey
        } else if let template = json["templateConfig"] as? [String: Any],
                  (template["templateType"] as? String) == "survey" {
            raw = template
        } else {
            raw = nil
        }
        guard let raw, let converted = surveyJSONObject(raw) else { return nil }
        return SurveyConfigModel.from(converted, fallbackId: fallbackId)
    }

    // ── guide parsing ─────────────────────────────────────────────────────────

    private static func parseGuideConfig(_ json: [String: Any], fallbackId: String) -> GuideConfigModel? {
        if let guideJson = json.object("guideConfig") {
            // Variables may live on guideConfig or on the sibling templateConfig
            let templateJson = json.object("templateConfig")
            let schemas = NudgeConfig.parseVariableSchemas(templateJson ?? guideJson)
            return parseGuideSteps(guideJson, fallbackId: fallbackId, variableSchemas: schemas)
        }
        if let templateJson = json.object("templateConfig") {
            let templateType = templateJson.string("templateType")
            if templateType == "tooltip" || templateType == "spotlight" {
                let schemas = NudgeConfig.parseVariableSchemas(templateJson)
                return parseFlatGuideTemplate(templateJson, fallbackId: fallbackId, variableSchemas: schemas)
            }
        }
        return nil
    }

    private static func parseGuideSteps(_ guideJson: [String: Any], fallbackId: String, variableSchemas: [VariableSchema]) -> GuideConfigModel? {
        let guideId = guideJson.nonBlankString("id") ?? guideJson.nonBlankString("_id") ?? fallbackId
        guard let stepsArr = guideJson["steps"] as? [Any] else { return nil }
        return buildGuideConfig(
            guideId: guideId,
            multiStep: guideJson.bool("multiStep", default: false),
            stepsArr: stepsArr,
            displayStyle: nil,
            variableSchemas: variableSchemas,
            widgetJsonForStep: { stepJson in stepJson.object("widgetConfig") }
        )
    }

    private static func parseFlatGuideTemplate(_ templateJson: [String: Any], fallbackId: String, variableSchemas: [VariableSchema]) -> GuideConfigModel? {
        guard let stepsArr = templateJson["steps"] as? [Any] else { return nil }
        return buildGuideConfig(
            guideId: templateJson.nonBlankString("templateId") ?? fallbackId,
            multiStep: stepsArr.count > 1,
            stepsArr: stepsArr,
            displayStyle: templateJson.string("templateType", default: "tooltip"),
            variableSchemas: variableSchemas,
            widgetJsonForStep: { stepJson in stepJson }
        )
    }

    private static func buildGuideConfig(
        guideId: String,
        multiStep: Bool,
        stepsArr: [Any],
        displayStyle: String?,
        variableSchemas: [VariableSchema],
        widgetJsonForStep: ([String: Any]) -> [String: Any]?
    ) -> GuideConfigModel? {
        var steps: [GuideStepModel] = []

        for (index, element) in stepsArr.enumerated() {
            guard let stepJson = element as? [String: Any] else { continue }
            let stepId = stepJson.nonBlankString("id") ?? stepJson.string("_id")
            guard let anchorKey = stepJson.nonBlankString("anchorKey") else { continue }
            guard let widgetJson = widgetJsonForStep(stepJson) else { continue }
            steps.append(
                GuideStepModel(
                    id: stepId,
                    sequenceOrder: stepJson.int("sequenceOrder", default: index),
                    anchorKey: anchorKey,
                    displayStyle: displayStyle ?? stepJson.string("displayStyle", default: "tooltip"),
                    widgetConfig: GuideStepWidgetConfig.fromJson(widgetJson),
                    advanceTrigger: stepJson.string("advanceTrigger", default: "tap"),
                    autoDelayMs: stepJson["autoDelayMs"] != nil ? stepJson.int("autoDelayMs", default: 0) : nil
                )
            )
        }

        if steps.isEmpty { return nil }
        return GuideConfigModel(
            id: guideId,
            multiStep: multiStep,
            steps: steps.sorted { $0.sequenceOrder < $1.sequenceOrder },
            variableSchemas: variableSchemas
        )
    }
}

// MARK: - [String: Any] → JSONValue bridge (survey config)

/// Converts a Foundation JSON object (`[String: Any]` from JSONSerialization)
/// into the SDK's `JSONValue` tree, which the survey parser consumes.
private func surveyJSONObject(_ dictionary: [String: Any]) -> [String: JSONValue]? {
    var result: [String: JSONValue] = [:]
    for (key, value) in dictionary {
        guard let mapped = surveyJSONValue(value) else { return nil }
        result[key] = mapped
    }
    return result
}

private func surveyJSONValue(_ value: Any) -> JSONValue? {
    switch value {
    case let string as String:
        return .string(string)
    // Bool must be checked before NSNumber/Int: JSONSerialization yields NSNumber
    // for both, and `as? Int` would also match a boolean.
    case let bool as Bool where value is Bool || CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID():
        return .bool(bool)
    case let int as Int:
        return .int(int)
    case let double as Double:
        return .double(double)
    case let number as NSNumber:
        // CFBoolean already handled above; treat the rest numerically.
        return .double(number.doubleValue)
    case let array as [Any]:
        var values: [JSONValue] = []
        for item in array {
            guard let mapped = surveyJSONValue(item) else { return nil }
            values.append(mapped)
        }
        return .array(values)
    case let object as [String: Any]:
        guard let mapped = surveyJSONObject(object) else { return nil }
        return .object(mapped)
    case is NSNull:
        return .null
    default:
        return nil
    }
}
