import Foundation

// Ported from Android `CampaignModel.kt`. Survey campaigns are intentionally
// not parsed here (no iOS survey model yet) — a "survey" campaignType yields nil
// and is skipped during fetch.

enum CampaignConfigModel: Equatable {
    case guide(GuideConfigModel)
    case nudge
    case inline(InlineCarouselConfig)
    case story(InlineStoryConfig)
}

struct CampaignModel: Equatable {
    let id: String
    let campaignKey: String
    let campaignType: String
    let config: CampaignConfigModel

    var guideConfig: GuideConfigModel? {
        if case let .guide(value) = config { return value }
        return nil
    }

    var inlineConfig: InlineCarouselConfig? {
        if case let .inline(value) = config { return value }
        return nil
    }

    var storyConfig: InlineStoryConfig? {
        if case let .story(value) = config { return value }
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
            config = .nudge
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
        default:
            // "survey" and any unknown type are skipped on iOS.
            return nil
        }

        return CampaignModel(id: id, campaignKey: campaignKey, campaignType: campaignType, config: config)
    }

    // ── guide parsing ─────────────────────────────────────────────────────────

    private static func parseGuideConfig(_ json: [String: Any], fallbackId: String) -> GuideConfigModel? {
        if let guideJson = json.object("guideConfig") {
            return parseGuideSteps(guideJson, fallbackId: fallbackId)
        }
        if let templateJson = json.object("templateConfig") {
            let templateType = templateJson.string("templateType")
            if templateType == "tooltip" || templateType == "spotlight" {
                return parseFlatGuideTemplate(templateJson, fallbackId: fallbackId)
            }
        }
        return nil
    }

    private static func parseGuideSteps(_ guideJson: [String: Any], fallbackId: String) -> GuideConfigModel? {
        let guideId = guideJson.nonBlankString("id") ?? guideJson.nonBlankString("_id") ?? fallbackId
        guard let stepsArr = guideJson["steps"] as? [Any] else { return nil }
        return buildGuideConfig(
            guideId: guideId,
            multiStep: guideJson.bool("multiStep", default: false),
            stepsArr: stepsArr,
            displayStyle: nil,
            widgetJsonForStep: { stepJson in stepJson.object("widgetConfig") }
        )
    }

    private static func parseFlatGuideTemplate(_ templateJson: [String: Any], fallbackId: String) -> GuideConfigModel? {
        guard let stepsArr = templateJson["steps"] as? [Any] else { return nil }
        return buildGuideConfig(
            guideId: templateJson.nonBlankString("templateId") ?? fallbackId,
            multiStep: stepsArr.count > 1,
            stepsArr: stepsArr,
            displayStyle: templateJson.string("templateType", default: "tooltip"),
            widgetJsonForStep: { stepJson in stepJson }
        )
    }

    private static func buildGuideConfig(
        guideId: String,
        multiStep: Bool,
        stepsArr: [Any],
        displayStyle: String?,
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
            steps: steps.sorted { $0.sequenceOrder < $1.sequenceOrder }
        )
    }
}
