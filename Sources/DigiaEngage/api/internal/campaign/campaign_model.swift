import Foundation

// Ported from Android `CampaignModel.kt`. Survey campaigns are delivered as the
// campaign's `surveyConfig` (or a `templateConfig` with `templateType ==
// "survey"`) and parsed into a `SurveyConfigModel`, mirroring Android.

enum CampaignConfigModel: Equatable {
    case guide(GuideConfigModel)
    case nudge(NudgeConfig)
    case inline(InlineCarouselConfig)
    case banner(InlineBannerConfig)
    /// A free-form Canvas campaign in a slot — the only inline kind whose content
    /// is authored rather than filled into a fixed shape, and so the only one
    /// that reuses the shared Canvas renderer.
    case inlineCanvas(InlineCanvasConfig)
    case story(InlineStoryConfig)
    case survey(SurveyConfigModel)
    case floater(FloaterConfig)
    /// The floater family's second member: a small floating **canvas** window that opens
    /// a full-screen story on tap. Shares the PiP's window vocabulary and none of its media.
    case floaterStory(FloaterStoryConfig)
}

struct CampaignModel: Equatable {
    let id: String
    let campaignKey: String
    let campaignType: String
    let config: CampaignConfigModel
    let targetScreenNames: [String]
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

    var bannerConfig: InlineBannerConfig? {
        if case let .banner(value) = config { return value }
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

    var floaterStoryConfig: FloaterStoryConfig? {
        if case let .floaterStory(value) = config { return value }
        return nil
    }

    var floaterConfig: FloaterConfig? {
        if case let .floater(value) = config { return value }
        return nil
    }

    static func fromJson(
        _ json: [String: Any],
        designTokens: DesignTokenCatalog = .empty,
        devicePlatform: String? = nil,
        timeAnchor: TrustedTimeAnchor? = nil,
        diagnostics: DiagnosticsReporter? = nil
    ) -> CampaignModel? {
        guard let selectedJson = selectForDevice(json, devicePlatform: devicePlatform) else { return nil }
        guard let id = selectedJson.nonBlankString("id") ?? selectedJson.nonBlankString("_id") else { return nil }
        guard let campaignKey = selectedJson.nonBlankString("campaignKey") else { return nil }
        guard let campaignType = selectedJson.nonBlankString("campaignType") else { return nil }
        let targetScreenNames = selectedJson.object("targetScreenNames")?.stringArray("names") ?? []

        let config: CampaignConfigModel
        switch campaignType {
        case "guide":
            guard let guideConfig = parseGuideConfig(
                selectedJson,
                fallbackId: id,
                designTokens: designTokens
            ) else { return nil }
            config = .guide(guideConfig)
        case "nudge":
            guard let templateConfig = selectedJson.object("templateConfig"),
                  let nudgeConfig = NudgeConfig.fromJson(templateConfig, designTokens: designTokens) else { return nil }
            config = .nudge(nudgeConfig)
        case "inline":
            guard let templateConfig = selectedJson.object("templateConfig") else { return nil }
            if templateConfig["stateful"] != nil {
                let schemas = NudgeConfig.parseVariableSchemas(templateConfig)
                guard let stateful = StatefulTimerConfig.fromJson(
                    templateConfig,
                    designTokens: designTokens,
                    timeAnchor: timeAnchor,
                    variableSchemas: schemas
                ) else {
                    return rejectUnsupportedStatefulCampaign(
                        campaignKey: campaignKey,
                        reason: "invalid inline timer stateful config",
                        diagnostics: diagnostics
                    )
                }
                guard var canvasConfig = InlineCanvasConfig.fromStatefulJson(
                    templateConfig,
                    stateful: stateful
                ) else {
                    return rejectUnsupportedStatefulCampaign(
                        campaignKey: campaignKey,
                        reason: "invalid inline timer templateConfig",
                        diagnostics: diagnostics
                    )
                }
                canvasConfig.variableSchemas = schemas
                config = .inlineCanvas(canvasConfig)
                break
            }
            switch templateConfig.string("templateType", default: "carousel") {
            case "banner":
                guard let bannerConfig = InlineBannerConfig.fromJson(templateConfig) else { return nil }
                config = .banner(bannerConfig)
            case "story":
                guard let storyConfig = InlineStoryConfig.fromJson(templateConfig) else { return nil }
                config = .story(storyConfig)
            // `canvasCarousel` and `canvasStory` are inline canvases whose canvas
            // contains one extra widget — the payloads are otherwise identical,
            // and the strip or rail is drawn by that widget's renderer. So
            // neither needs a campaign type of its own; the dashboard keeps the
            // distinct subtypes only to guarantee the widget is present and
            // undeletable.
            case "canvas", "canvasCarousel", "canvasStory":
                guard let canvasConfig = InlineCanvasConfig.fromJson(
                    templateConfig,
                    designTokens: designTokens
                ) else { return nil }
                config = .inlineCanvas(canvasConfig)
            default:
                guard let carouselConfig = InlineCarouselConfig.fromJson(templateConfig) else { return nil }
                config = .inline(carouselConfig)
            }
        case "survey":
            guard let surveyConfig = parseSurveyConfig(selectedJson, fallbackId: id) else { return nil }
            config = .survey(surveyConfig)
        case "floater":
            guard let templateConfig = selectedJson.object("templateConfig") else { return nil }
            // Two template shapes under one campaign type: `pip` is a media window,
            // `floaterStory` a canvas window that opens a story — the same way `inline`
            // carries `carousel` / `story` / `banner`.
            if templateConfig.string("templateType", default: "pip") == "floaterStory" {
                guard let storyConfig = FloaterStoryConfig.fromJson(
                    templateConfig, designTokens: designTokens
                ) else { return nil }
                config = .floaterStory(storyConfig)
            } else {
                guard let floaterConfig = FloaterConfig.fromJson(
                    templateConfig, designTokens: designTokens
                ) else { return nil }
                config = .floater(floaterConfig)
            }
        default:
            // Any unknown type is skipped.
            return nil
        }

        return CampaignModel(
            id: id,
            campaignKey: campaignKey,
            campaignType: campaignType,
            config: config,
            targetScreenNames: targetScreenNames,
            frequency: FrequencyPolicy.fromJson(selectedJson.object("frequency"))
        )
    }

    private static func rejectUnsupportedStatefulCampaign(
        campaignKey: String,
        reason: String,
        diagnostics: DiagnosticsReporter?
    ) -> CampaignModel? {
        DigiaLog.warning("[CampaignModel] campaign_skipped_unsupported: \(reason)")
        diagnostics?.reportHealthEvent(
            "campaign_skipped_unsupported",
            params: ["campaign_key": campaignKey, "reason": reason]
        )
        return nil
    }

    private static func selectForDevice(
        _ json: [String: Any],
        devicePlatform: String?
    ) -> [String: Any]? {
        if let platforms = json["deliveryPlatforms"] as? [Any], !platforms.isEmpty {
            guard let devicePlatform,
                  platforms.contains(where: { $0 as? String == devicePlatform })
            else { return nil }
        }

        guard let template = json["templateConfig"] as? [String: Any],
              let steps = template["steps"] as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: json),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var copiedSteps = copy["templateConfig"] as? [String: Any],
              var copiedStepsArray = copiedSteps["steps"] as? [Any]
        else { return json }

        for (index, step) in steps.enumerated() {
            guard let step = step as? [String: Any],
                  let target = step["target"] as? [String: Any],
                  target["type"] as? String == "anchorless"
            else { continue }
            guard target.int("version", default: -1) == 1 else { return nil }
            guard let variants = target["variants"] else { continue }
            guard let devicePlatform,
                  let variantMap = variants as? [String: Any],
                  let variant = variantMap[devicePlatform] as? [String: Any],
                  variant["devicePlatform"] as? String == devicePlatform
            else { return nil }

            var selected = variant
            selected["type"] = "anchorless"
            selected["version"] = target["version"]
            guard var copiedStep = copiedStepsArray[index] as? [String: Any] else { return nil }
            copiedStep["target"] = selected
            copiedStepsArray[index] = copiedStep
        }

        copiedSteps["steps"] = copiedStepsArray
        var selected = copy
        selected["templateConfig"] = copiedSteps
        return selected
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

    private static func parseGuideConfig(
        _ json: [String: Any],
        fallbackId: String,
        designTokens: DesignTokenCatalog
    ) -> GuideConfigModel? {
        if let guideJson = json.object("guideConfig") {
            // Variables may live on guideConfig or on the sibling templateConfig
            let templateJson = json.object("templateConfig")
            let schemas = NudgeConfig.parseVariableSchemas(templateJson ?? guideJson)
            return parseGuideSteps(
                guideJson,
                fallbackId: fallbackId,
                variableSchemas: schemas,
                designTokens: designTokens
            )
        }
        if let templateJson = json.object("templateConfig") {
            let templateType = templateJson.string("templateType")
            if templateType == "tooltip" || templateType == "spotlight" {
                let schemas = NudgeConfig.parseVariableSchemas(templateJson)
                return parseFlatGuideTemplate(
                    templateJson,
                    fallbackId: fallbackId,
                    variableSchemas: schemas,
                    designTokens: designTokens
                )
            }
        }
        return nil
    }

    private static func parseGuideSteps(
        _ guideJson: [String: Any],
        fallbackId: String,
        variableSchemas: [VariableSchema],
        designTokens: DesignTokenCatalog
    ) -> GuideConfigModel? {
        let guideId = guideJson.nonBlankString("id") ?? guideJson.nonBlankString("_id") ?? fallbackId
        guard let stepsArr = guideJson["steps"] as? [Any] else { return nil }
        return buildGuideConfig(
            guideId: guideId,
            multiStep: guideJson.bool("multiStep", default: false),
            stepsArr: stepsArr,
            displayStyle: nil,
            variableSchemas: variableSchemas,
            designTokens: designTokens,
            designWidth: defaultCampaignCanvasDesignWidth,
            widgetJsonForStep: { stepJson in stepJson.object("widgetConfig") }
        )
    }

    private static func parseFlatGuideTemplate(
        _ templateJson: [String: Any],
        fallbackId: String,
        variableSchemas: [VariableSchema],
        designTokens: DesignTokenCatalog
    ) -> GuideConfigModel? {
        guard let stepsArr = templateJson["steps"] as? [Any] else { return nil }
        let rawDesignWidth = CGFloat(templateJson.double(
            "designWidth",
            default: Double(defaultCampaignCanvasDesignWidth)
        ))
        return buildGuideConfig(
            guideId: templateJson.nonBlankString("templateId") ?? fallbackId,
            multiStep: stepsArr.count > 1,
            stepsArr: stepsArr,
            displayStyle: templateJson.string("templateType", default: "tooltip"),
            variableSchemas: variableSchemas,
            designTokens: designTokens,
            designWidth: rawDesignWidth.isFinite && rawDesignWidth > 0
                ? rawDesignWidth
                : defaultCampaignCanvasDesignWidth,
            widgetJsonForStep: { stepJson in
                var widget = stepJson
                widget["outsideTapBehavior"] = templateJson.string(
                    "outsideTapBehavior",
                    default: "next"
                )
                return widget
            }
        )
    }

    private static func buildGuideConfig(
        guideId: String,
        multiStep: Bool,
        stepsArr: [Any],
        displayStyle: String?,
        variableSchemas: [VariableSchema],
        designTokens: DesignTokenCatalog,
        designWidth: CGFloat,
        widgetJsonForStep: ([String: Any]) -> [String: Any]?
    ) -> GuideConfigModel? {
        var steps: [GuideStepModel] = []
        let hasRawAnchorlessStep = stepsArr.contains { element in
            guard let step = element as? [String: Any],
                  let target = step.object("target")
            else { return false }
            return target.string("type") == "anchorless"
        }

        for (index, element) in stepsArr.enumerated() {
            guard let stepJson = element as? [String: Any] else { continue }
            let explicitStepId = stepJson.nonBlankString("stepId")
            let stepId = explicitStepId
                ?? stepJson.nonBlankString("id")
                ?? stepJson.string("_id")
            let configuredAnchorKey = stepJson.nonBlankString("anchorKey")
            let anchorlessTarget = stepJson.object("target")
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap(AnchorlessTarget.decode)
            let target: GuideTarget
            if let anchorKey = configuredAnchorKey, anchorlessTarget == nil {
                target = .registeredAnchor(anchorKey)
            } else if configuredAnchorKey == nil, let anchorless = anchorlessTarget {
                target = .anchorless(anchorless)
            } else {
                continue
            }
            guard let widgetJson = widgetJsonForStep(stepJson) else { continue }
            if displayStyle != nil {
                let outsideTapBehavior = widgetJson.string("outsideTapBehavior", default: "next")
                guard outsideTapBehavior == "next" || outsideTapBehavior == "nothing" else {
                    return nil
                }
            }
            let widgetConfig = GuideStepWidgetConfig.fromJson(
                widgetJson,
                displayStyle: displayStyle,
                designTokens: designTokens
            )
            if case .anchorless = target {
                let outsideTapBehavior = widgetJson.string("outsideTapBehavior", default: "next")
                guard displayStyle == "spotlight",
                      explicitStepId != nil,
                      widgetConfig.layoutMode == "canvas",
                      widgetConfig.canvas != nil,
                      outsideTapBehavior == "next" || outsideTapBehavior == "nothing"
                else { return nil }
            }
            steps.append(
                GuideStepModel(
                    id: stepId,
                    sequenceOrder: stepJson.int("sequenceOrder", default: index),
                    target: target,
                    displayStyle: displayStyle ?? stepJson.string("displayStyle", default: "tooltip"),
                    widgetConfig: widgetConfig,
                    advanceTrigger: stepJson.string("advanceTrigger", default: "tap"),
                    autoDelayMs: stepJson["autoDelayMs"] != nil ? stepJson.int("autoDelayMs", default: 0) : nil,
                    delayInMs: displayStyle != nil && stepJson["delayInMs"] != nil
                        ? stepJson.int("delayInMs", default: 0)
                        : nil
                )
            )
        }

        if steps.isEmpty { return nil }
        let anchorlessTargets = steps.compactMap { step -> AnchorlessTarget? in
            if case let .anchorless(target) = step.target { return target }
            return nil
        }
        if hasRawAnchorlessStep {
            guard steps.count == stepsArr.count,
                  anchorlessTargets.count == steps.count,
                  Set(steps.map(\.id)).count == steps.count,
                  Set(anchorlessTargets.map(\.pageKey)).count == 1
            else { return nil }
        }
        return GuideConfigModel(
            id: guideId,
            multiStep: multiStep,
            designWidth: designWidth,
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
