import CoreFoundation
import Foundation

enum AssistedPlatform: String, Equatable {
    case android
    case ios

    var logicalUnit: String { self == .android ? "dp" : "pt" }
}

enum AssistedFailure: String, Equatable {
    case campaignModeMismatch = "campaign_mode_mismatch"
    case unsupportedTargetVersion = "unsupported_target_version"
    case missingPlatformVariant = "missing_platform_variant"
    case platformMismatch = "platform_mismatch"
    case logicalUnitMismatch = "logical_unit_mismatch"
    case unsupportedModelVersion = "unsupported_model_version"
    case unsupportedOrientation = "unsupported_orientation"
    case invalidSource = "invalid_source"
    case invalidAuthorIntent = "invalid_author_intent"
    case invalidReferenceContainer = "invalid_reference_container"
    case invalidModel = "invalid_model"
    case invalidRuntimeFrame = "invalid_runtime_frame"
    case pageMismatch = "page_mismatch"
    case appIdentifierMismatch = "app_identifier_mismatch"
    case unsupportedFormFactor = "unsupported_form_factor"
    case targetOutOfBounds = "target_out_of_bounds"
}

enum AssistedWarning: String, Equatable {
    case appBuildMismatch = "app_build_mismatch"
    case localeMismatch = "locale_mismatch"
    case fontScaleMismatch = "font_scale_mismatch"
    case scrollStateUnverifiable = "scroll_state_unverifiable"
}

struct EdgeRectV1: Equatable {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double

    var width: Double { right - left }
    var height: Double { bottom - top }

    var isFinitePositive: Bool {
        left.isFinite && top.isFinite && right.isFinite && bottom.isFinite && width > 0 && height > 0
    }

    func contains(_ other: EdgeRectV1, tolerance: Double = 0) -> Bool {
        other.left >= left - tolerance && other.top >= top - tolerance
            && other.right <= right + tolerance && other.bottom <= bottom + tolerance
    }

    static func fromJson(_ json: [String: Any]?) -> EdgeRectV1? {
        guard let json,
              let left = json.strictDouble("left"),
              let top = json.strictDouble("top"),
              let right = json.strictDouble("right"),
              let bottom = json.strictDouble("bottom")
        else { return nil }
        let value = EdgeRectV1(left: left, top: top, right: right, bottom: bottom)
        return value.isFinitePositive ? value : nil
    }
}

enum GeometryFrameV1: String, Equatable {
    case window
    case appContent
    case referenceContainer
}

enum HorizontalRuleV1: Equatable {
    case startFixed(startOffset: Double, width: Double)
    case endFixed(endOffset: Double, width: Double)
    case centerFixed(centerOffset: Double, width: Double)
    case stretch(startInset: Double, endInset: Double)
    case proportional(startFraction: Double, endFraction: Double)
}

enum VerticalRuleV1: Equatable {
    case topFixed(topOffset: Double, height: Double)
    case bottomFixed(bottomOffset: Double, height: Double)
    case centerFixed(centerOffset: Double, height: Double)
    case stretch(topInset: Double, bottomInset: Double)
    case proportional(topFraction: Double, bottomFraction: Double)
}

struct HorizontalAxisModelV1: Equatable {
    let frame: GeometryFrameV1
    let rule: HorizontalRuleV1
}

struct VerticalAxisModelV1: Equatable {
    let frame: GeometryFrameV1
    let rule: VerticalRuleV1
}

struct TargetGeometryModelV1: Equatable {
    let horizontal: HorizontalAxisModelV1
    let vertical: VerticalAxisModelV1
}

struct ReferenceContainerV1: Equatable {
    let sourceBoundsPx: EdgeRectV1
    let model: TargetGeometryModelV1
}

struct AssistedComparisonContextV1: Equatable {
    let appIdentifier: String
    let appBuild: String
    let locale: String
    let fontScale: Double
    let riskFlags: [String]
}

struct PreparedAssistedStepV1: Equatable {
    let stepId: String
    let variantId: String
    let captureId: String
    let platform: AssistedPlatform
    let pageKey: String
    let sourceDensity: Double
    let sourceWindowBoundsPx: EdgeRectV1
    let sourceAppContentBoundsPx: EdgeRectV1
    let sourceLayoutDirection: String
    let authorIntentPx: EdgeRectV1
    let comparisonContext: AssistedComparisonContextV1
    let referenceContainer: ReferenceContainerV1?
    let model: TargetGeometryModelV1
}

struct PreparedAssistedCampaignV1: Equatable {
    let campaignKey: String?
    let platform: AssistedPlatform
    let steps: [PreparedAssistedStepV1]
    private let stepsById: [String: PreparedAssistedStepV1]

    init(campaignKey: String?, platform: AssistedPlatform, steps: [PreparedAssistedStepV1]) {
        self.campaignKey = campaignKey
        self.platform = platform
        self.steps = steps
        stepsById = Dictionary(uniqueKeysWithValues: steps.map { ($0.stepId, $0) })
    }

    func step(_ stepId: String) -> PreparedAssistedStepV1? {
        stepsById[stepId]
    }
}

struct RuntimeGeometrySnapshotV1: Equatable {
    let snapshotVersion: Int
    let platform: AssistedPlatform?
    let pageKey: String?
    let density: Double
    let windowBoundsPx: EdgeRectV1?
    let appContentBoundsPx: EdgeRectV1?
    let layoutDirection: String
    let orientation: String
    let formFactor: String
    let appIdentifier: String
    let appBuild: String
    let locale: String
    let fontScale: Double

    static func fromJson(_ json: [String: Any]) -> RuntimeGeometrySnapshotV1 {
        RuntimeGeometrySnapshotV1(
            snapshotVersion: json.int("snapshotVersion", default: -1),
            platform: AssistedPlatform(rawValue: json.string("platform")),
            pageKey: json["pageKey"] as? String,
            density: json.strictDouble("density") ?? .nan,
            windowBoundsPx: EdgeRectV1.fromJson(json.object("windowBoundsPx")),
            appContentBoundsPx: EdgeRectV1.fromJson(json.object("appContentBoundsPx")),
            layoutDirection: json.string("layoutDirection"),
            orientation: json.string("orientation"),
            formFactor: json.string("formFactor"),
            appIdentifier: json.string("appIdentifier"),
            appBuild: json.string("appBuild"),
            locale: json.string("locale"),
            fontScale: json.strictDouble("fontScale") ?? .nan
        )
    }
}

struct AssistedGeometryTraceV1: Equatable {
    let outcome: String
    let campaignKey: String?
    let stepId: String?
    let variantId: String?
    let captureId: String?
    let warnings: [AssistedWarning]
    let failure: AssistedFailure?
    let roundedTargetPx: EdgeRectV1?
}

enum AssistedPreparation: Equatable {
    case prepared(PreparedAssistedCampaignV1)
    case rejected(AssistedFailure, AssistedGeometryTraceV1)
}

enum AssistedResolution: Equatable {
    case resolved(
        status: String,
        roundedTargetPx: EdgeRectV1,
        overlayTarget: EdgeRectV1,
        warnings: [AssistedWarning],
        trace: AssistedGeometryTraceV1
    )
    case failed(AssistedFailure, AssistedGeometryTraceV1)
}

enum AssistedGeometryRuntimeV1 {
    private static let containmentTolerancePx = 0.000001
    static let diagnostics = AssistedGeometryDiagnosticsV1()

    static func isAssistedCampaign(_ rawCampaign: [String: Any]) -> Bool {
        let config = rawCampaign.object("templateConfig") ?? rawCampaign
        guard config.string("templateType") == "spotlight",
              let steps = config["steps"] as? [Any], !steps.isEmpty
        else { return false }
        return steps.contains { element in
            guard let step = element as? [String: Any] else { return false }
            return step.object("target")?.string("type") == "assistedGeometry"
        }
    }

    static func prepare(_ rawCampaign: [String: Any], platform: AssistedPlatform) -> AssistedPreparation {
        let campaignKey = rawCampaign.nonBlankString("campaignKey")
        let config = rawCampaign.object("templateConfig") ?? rawCampaign
        guard config.string("templateType") == "spotlight",
              let elements = config["steps"] as? [Any], !elements.isEmpty,
              elements.count == elements.compactMap({ $0 as? [String: Any] }).count
        else { return rejected(campaignKey, .campaignModeMismatch) }
        let rawSteps = elements.compactMap { $0 as? [String: Any] }
        guard rawSteps.allSatisfy({ step in
            step.nonBlankString("anchorKey") == nil
                && step.object("target")?.string("type") == "assistedGeometry"
        }) else { return rejected(campaignKey, .campaignModeMismatch) }

        guard rawSteps.allSatisfy({ $0.object("target")?.int("version", default: -1) == 1 })
        else { return rejected(campaignKey, .unsupportedTargetVersion) }

        guard rawSteps.allSatisfy({
            $0.object("target")?.object("variants")?.object(platform.rawValue) != nil
        }) else { return rejected(campaignKey, .missingPlatformVariant) }

        guard let deliveryRaw = config["deliveryPlatforms"] as? [Any] else {
            return rejected(campaignKey, .platformMismatch)
        }
        let delivery = deliveryRaw.compactMap { $0 as? String }
        let canonical = delivery.sorted { ($0 == "android" ? 0 : 1) < ($1 == "android" ? 0 : 1) }
        let allowed = Set(["android", "ios"])
        let deliveryValid = !delivery.isEmpty
            && delivery.count == deliveryRaw.count
            && Set(delivery).count == delivery.count
            && delivery.allSatisfy(allowed.contains)
            && delivery == canonical
            && delivery.contains(platform.rawValue)
        guard deliveryValid && rawSteps.allSatisfy({ step in
            guard let variants = step.object("target")?.object("variants"),
                  variants.keys.allSatisfy({ delivery.contains($0) }),
                  variants.object(platform.rawValue)?.string("platform") == platform.rawValue
            else { return false }
            return true
        }) else { return rejected(campaignKey, .platformMismatch) }

        let variants = rawSteps.compactMap {
            $0.object("target")?.object("variants")?.object(platform.rawValue)
        }
        guard variants.allSatisfy({ $0.string("logicalUnit") == platform.logicalUnit })
        else { return rejected(campaignKey, .logicalUnitMismatch) }

        guard variants.allSatisfy({ variant in
            guard variant.object("model")?.int("version", default: -1) == 1 else { return false }
            if let container = variant.object("referenceContainer") {
                return container.object("model")?.int("version", default: -1) == 1
            }
            return true
        }) else { return rejected(campaignKey, .unsupportedModelVersion) }

        guard variants.allSatisfy({ $0.string("orientation") == "portrait" })
        else { return rejected(campaignKey, .unsupportedOrientation) }

        var parsedSources: [ParsedSource] = []
        var stepIds = Set<String>()
        var variantIds = Set<String>()
        for (index, step) in rawSteps.enumerated() {
            let variant = variants[index]
            let stepId = step.string("stepId")
            let variantId = variant.string("variantId")
            let captureId = variant.string("captureId")
            let pageKey = variant.string("pageKey")
            let source = variant.object("source")
            let comparison = variant.object("comparisonContext")
            let density = source?.strictDouble("density")
            let window = EdgeRectV1.fromJson(source?.object("windowBoundsPx"))
            let content = EdgeRectV1.fromJson(source?.object("appContentBoundsPx"))
            let direction = source?.string("layoutDirection") ?? ""
            let appIdentifier = comparison?.string("appIdentifier") ?? ""
            let appBuild = comparison?.string("appBuild") ?? ""
            let locale = comparison?.string("locale") ?? ""
            let fontScale = comparison?.strictDouble("fontScale")
            let riskFlagsRaw = comparison?["riskFlags"] as? [Any] ?? []
            let riskFlags = riskFlagsRaw.compactMap { $0 as? String }
            guard isUUID(stepId), stepIds.insert(stepId).inserted,
                  isUUID(variantId), variantIds.insert(variantId).inserted,
                  !captureId.isEmpty, !pageKey.isEmpty,
                  let density, density.isFinite, density > 0,
                  let window, let content, window.contains(content),
                  direction == "ltr" || direction == "rtl",
                  !appIdentifier.isEmpty, !appBuild.isEmpty, !locale.isEmpty,
                  let fontScale, fontScale.isFinite, fontScale > 0,
                  riskFlags.count == riskFlagsRaw.count
            else { return rejected(campaignKey, .invalidSource, stepId: stepId) }
            parsedSources.append(ParsedSource(
                stepId: stepId, variantId: variantId, captureId: captureId, pageKey: pageKey,
                density: density, window: window, content: content, layoutDirection: direction,
                comparison: AssistedComparisonContextV1(
                    appIdentifier: appIdentifier, appBuild: appBuild, locale: locale,
                    fontScale: fontScale, riskFlags: riskFlags
                )
            ))
        }

        let intents = variants.map { EdgeRectV1.fromJson($0.object("authorIntentPx")) }
        guard intents.allSatisfy({ $0 != nil }), intents.indices.allSatisfy({ index in
            parsedSources[index].window.contains(intents[index]!)
        }) else { return rejected(campaignKey, .invalidAuthorIntent) }

        var containers: [ReferenceContainerV1?] = []
        for (index, variant) in variants.enumerated() {
            guard let raw = variant.object("referenceContainer") else {
                containers.append(nil)
                continue
            }
            guard let bounds = EdgeRectV1.fromJson(raw.object("sourceBoundsPx")),
                  parsedSources[index].window.contains(bounds),
                  bounds.contains(intents[index]!),
                  let model = parseModel(raw.object("model"), allowReference: false)
            else { return rejected(campaignKey, .invalidReferenceContainer) }
            containers.append(ReferenceContainerV1(sourceBoundsPx: bounds, model: model))
        }

        let models = variants.map { parseModel($0.object("model"), allowReference: true) }
        guard models.allSatisfy({ $0 != nil }) else { return rejected(campaignKey, .invalidModel) }
        guard models.indices.allSatisfy({ index in
            let model = models[index]!
            let needsContainer = model.horizontal.frame == .referenceContainer
                || model.vertical.frame == .referenceContainer
            return !needsContainer || containers[index] != nil
        }) else { return rejected(campaignKey, .invalidReferenceContainer) }

        let prepared = rawSteps.indices.map { index -> PreparedAssistedStepV1 in
            let source = parsedSources[index]
            return PreparedAssistedStepV1(
                stepId: source.stepId, variantId: source.variantId, captureId: source.captureId,
                platform: platform, pageKey: source.pageKey, sourceDensity: source.density,
                sourceWindowBoundsPx: source.window, sourceAppContentBoundsPx: source.content,
                sourceLayoutDirection: source.layoutDirection, authorIntentPx: intents[index]!,
                comparisonContext: source.comparison, referenceContainer: containers[index],
                model: models[index]!
            )
        }
        guard prepared.allSatisfy(replaysSource) else { return rejected(campaignKey, .invalidModel) }
        return .prepared(PreparedAssistedCampaignV1(
            campaignKey: campaignKey, platform: platform, steps: prepared
        ))
    }

    static func resolve(
        _ campaign: PreparedAssistedCampaignV1,
        stepId: String,
        snapshot: RuntimeGeometrySnapshotV1
    ) -> AssistedResolution {
        guard let step = campaign.step(stepId) else {
            return failed(campaign.campaignKey, nil, .invalidModel)
        }
        guard snapshot.snapshotVersion == 1, snapshot.platform == campaign.platform,
              snapshot.density.isFinite, snapshot.density > 0,
              snapshot.fontScale.isFinite, snapshot.fontScale > 0,
              let window = snapshot.windowBoundsPx, let content = snapshot.appContentBoundsPx,
              window.left == 0, window.top == 0, window.contains(content),
              snapshot.layoutDirection == "ltr" || snapshot.layoutDirection == "rtl",
              !snapshot.appIdentifier.isEmpty, !snapshot.appBuild.isEmpty, !snapshot.locale.isEmpty
        else { return failed(campaign.campaignKey, step, .invalidRuntimeFrame) }
        guard snapshot.pageKey == step.pageKey else {
            return failed(campaign.campaignKey, step, .pageMismatch)
        }
        guard snapshot.appIdentifier == step.comparisonContext.appIdentifier else {
            return failed(campaign.campaignKey, step, .appIdentifierMismatch)
        }
        guard snapshot.orientation == "portrait" else {
            return failed(campaign.campaignKey, step, .unsupportedOrientation)
        }
        guard snapshot.formFactor == "phone" else {
            return failed(campaign.campaignKey, step, .unsupportedFormFactor)
        }
        let warningValues = warnings(step.comparisonContext, snapshot)
        let rtl = snapshot.layoutDirection == "rtl"
        let container: EdgeRectV1?
        if let reference = step.referenceContainer {
            guard let raw = resolveModel(reference.model, window, content, nil, snapshot.density, rtl),
                  let normalized = normalizeContained(
                    raw,
                    horizontalBasis(reference.model.horizontal.frame, window, content, nil),
                    verticalBasis(reference.model.vertical.frame, window, content, nil),
                    window
                  )
            else { return failed(campaign.campaignKey, step, .invalidReferenceContainer) }
            container = normalized
        } else {
            container = nil
        }
        guard let rawTarget = resolveModel(step.model, window, content, container, snapshot.density, rtl)
        else { return failed(campaign.campaignKey, step, .invalidModel) }
        guard let normalized = normalizeContained(
            rawTarget,
            horizontalBasis(step.model.horizontal.frame, window, content, container),
            verticalBasis(step.model.vertical.frame, window, content, container),
            window
        ) else { return failed(campaign.campaignKey, step, .targetOutOfBounds) }
        let rounded = EdgeRectV1(
            left: roundHalfUp(normalized.left), top: roundHalfUp(normalized.top),
            right: roundHalfUp(normalized.right), bottom: roundHalfUp(normalized.bottom)
        )
        guard rounded.isFinitePositive else { return failed(campaign.campaignKey, step, .invalidModel) }
        let overlay = EdgeRectV1(
            left: rounded.left / snapshot.density, top: rounded.top / snapshot.density,
            right: rounded.right / snapshot.density, bottom: rounded.bottom / snapshot.density
        )
        let outcome = warningValues.isEmpty ? "resolved" : "warning"
        let trace = AssistedGeometryTraceV1(
            outcome: outcome, campaignKey: campaign.campaignKey, stepId: step.stepId,
            variantId: step.variantId, captureId: step.captureId, warnings: warningValues,
            failure: nil, roundedTargetPx: rounded
        )
        diagnostics.append(trace)
        return .resolved(
            status: outcome, roundedTargetPx: rounded, overlayTarget: overlay,
            warnings: warningValues, trace: trace
        )
    }

    static func resolveGeometryModel(
        _ model: TargetGeometryModelV1,
        window: EdgeRectV1,
        content: EdgeRectV1,
        density: Double,
        rtl: Bool
    ) -> EdgeRectV1? {
        guard let raw = resolveModel(model, window, content, nil, density, rtl),
              let normalized = normalizeContained(
                raw,
                horizontalBasis(model.horizontal.frame, window, content, nil),
                verticalBasis(model.vertical.frame, window, content, nil),
                window
              )
        else { return nil }
        let rounded = EdgeRectV1(
            left: roundHalfUp(normalized.left), top: roundHalfUp(normalized.top),
            right: roundHalfUp(normalized.right), bottom: roundHalfUp(normalized.bottom)
        )
        return rounded.isFinitePositive ? rounded : nil
    }

    private static func replaysSource(_ step: PreparedAssistedStepV1) -> Bool {
        let rtl = step.sourceLayoutDirection == "rtl"
        let container: EdgeRectV1?
        if let reference = step.referenceContainer {
            guard let raw = resolveModel(
                reference.model, step.sourceWindowBoundsPx, step.sourceAppContentBoundsPx,
                nil, step.sourceDensity, rtl
            ), let normalized = normalizeContained(
                raw,
                horizontalBasis(reference.model.horizontal.frame, step.sourceWindowBoundsPx, step.sourceAppContentBoundsPx, nil),
                verticalBasis(reference.model.vertical.frame, step.sourceWindowBoundsPx, step.sourceAppContentBoundsPx, nil),
                step.sourceWindowBoundsPx
            ) else { return false }
            container = normalized
        } else {
            container = nil
        }
        guard let target = resolveModel(
            step.model, step.sourceWindowBoundsPx, step.sourceAppContentBoundsPx,
            container, step.sourceDensity, rtl
        ) else { return false }
        return normalizeContained(
            target,
            horizontalBasis(step.model.horizontal.frame, step.sourceWindowBoundsPx, step.sourceAppContentBoundsPx, container),
            verticalBasis(step.model.vertical.frame, step.sourceWindowBoundsPx, step.sourceAppContentBoundsPx, container),
            step.sourceWindowBoundsPx
        ) != nil
    }

    private static func resolveModel(
        _ model: TargetGeometryModelV1,
        _ window: EdgeRectV1,
        _ content: EdgeRectV1,
        _ container: EdgeRectV1?,
        _ density: Double,
        _ rtl: Bool
    ) -> EdgeRectV1? {
        guard let horizontalFrame = horizontalBasis(model.horizontal.frame, window, content, container),
              let verticalFrame = verticalBasis(model.vertical.frame, window, content, container),
              let horizontal = resolveHorizontal(model.horizontal.rule, horizontalFrame, density, rtl),
              let vertical = resolveVertical(model.vertical.rule, verticalFrame, density)
        else { return nil }
        let rect = EdgeRectV1(left: horizontal.0, top: vertical.0, right: horizontal.1, bottom: vertical.1)
        return rect.isFinitePositive ? rect : nil
    }

    private static func resolveHorizontal(
        _ rule: HorizontalRuleV1, _ frame: EdgeRectV1, _ density: Double, _ rtl: Bool
    ) -> (Double, Double)? {
        let value: (Double, Double)
        switch rule {
        case let .startFixed(offset, width):
            value = rtl
                ? (frame.right - offset * density - width * density, frame.right - offset * density)
                : (frame.left + offset * density, frame.left + (offset + width) * density)
        case let .endFixed(offset, width):
            value = rtl
                ? (frame.left + offset * density, frame.left + (offset + width) * density)
                : (frame.right - (offset + width) * density, frame.right - offset * density)
        case let .centerFixed(offset, width):
            let center = (frame.left + frame.right) / 2 + offset * density
            value = (center - width * density / 2, center + width * density / 2)
        case let .stretch(start, end):
            value = rtl
                ? (frame.left + end * density, frame.right - start * density)
                : (frame.left + start * density, frame.right - end * density)
        case let .proportional(start, end):
            value = rtl
                ? (frame.right - end * frame.width, frame.right - start * frame.width)
                : (frame.left + start * frame.width, frame.left + end * frame.width)
        }
        return value.0.isFinite && value.1.isFinite && value.1 > value.0 ? value : nil
    }

    private static func resolveVertical(
        _ rule: VerticalRuleV1, _ frame: EdgeRectV1, _ density: Double
    ) -> (Double, Double)? {
        let value: (Double, Double)
        switch rule {
        case let .topFixed(offset, height):
            let top = frame.top + offset * density
            value = (top, top + height * density)
        case let .bottomFixed(offset, height):
            let bottom = frame.bottom - offset * density
            value = (bottom - height * density, bottom)
        case let .centerFixed(offset, height):
            let center = (frame.top + frame.bottom) / 2 + offset * density
            value = (center - height * density / 2, center + height * density / 2)
        case let .stretch(top, bottom):
            value = (frame.top + top * density, frame.bottom - bottom * density)
        case let .proportional(top, bottom):
            value = (frame.top + top * frame.height, frame.top + bottom * frame.height)
        }
        return value.0.isFinite && value.1.isFinite && value.1 > value.0 ? value : nil
    }

    private static func horizontalBasis(
        _ frame: GeometryFrameV1, _ window: EdgeRectV1, _ content: EdgeRectV1, _ container: EdgeRectV1?
    ) -> EdgeRectV1? {
        switch frame {
        case .window: window
        case .appContent: content
        case .referenceContainer: container
        }
    }

    private static func verticalBasis(
        _ frame: GeometryFrameV1, _ window: EdgeRectV1, _ content: EdgeRectV1, _ container: EdgeRectV1?
    ) -> EdgeRectV1? {
        horizontalBasis(frame, window, content, container)
    }

    private static func normalizeContained(
        _ rect: EdgeRectV1,
        _ horizontal: EdgeRectV1?,
        _ vertical: EdgeRectV1?,
        _ window: EdgeRectV1
    ) -> EdgeRectV1? {
        guard let horizontal, let vertical,
              let left = normalizeLower(rect.left, max(window.left, horizontal.left)),
              let right = normalizeUpper(rect.right, min(window.right, horizontal.right)),
              let top = normalizeLower(rect.top, max(window.top, vertical.top)),
              let bottom = normalizeUpper(rect.bottom, min(window.bottom, vertical.bottom))
        else { return nil }
        let result = EdgeRectV1(left: left, top: top, right: right, bottom: bottom)
        return result.isFinitePositive ? result : nil
    }

    private static func normalizeLower(_ value: Double, _ lower: Double) -> Double? {
        if value >= lower { return value }
        return lower - value <= containmentTolerancePx ? lower : nil
    }

    private static func normalizeUpper(_ value: Double, _ upper: Double) -> Double? {
        if value <= upper { return value }
        return value - upper <= containmentTolerancePx ? upper : nil
    }

    private static func roundHalfUp(_ value: Double) -> Double { floor(value + 0.5) }

    private static func warnings(
        _ comparison: AssistedComparisonContextV1, _ snapshot: RuntimeGeometrySnapshotV1
    ) -> [AssistedWarning] {
        var result: [AssistedWarning] = []
        if comparison.appBuild != snapshot.appBuild { result.append(.appBuildMismatch) }
        if normalizeLocale(comparison.locale) != normalizeLocale(snapshot.locale) {
            result.append(.localeMismatch)
        }
        if abs(roundThousandths(comparison.fontScale) - roundThousandths(snapshot.fontScale)) > 10 {
            result.append(.fontScaleMismatch)
        }
        if comparison.riskFlags.contains("scrollableSelection") {
            result.append(.scrollStateUnverifiable)
        }
        return result
    }

    private static func normalizeLocale(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func roundThousandths(_ value: Double) -> Int { Int(floor(value * 1000 + 0.5)) }

    private static func parseModel(_ json: [String: Any]?, allowReference: Bool) -> TargetGeometryModelV1? {
        guard let json, json.int("version", default: -1) == 1,
              let horizontal = json.object("horizontal"), let vertical = json.object("vertical"),
              let horizontalFrame = GeometryFrameV1(rawValue: horizontal.string("frame")),
              let verticalFrame = GeometryFrameV1(rawValue: vertical.string("frame")),
              allowReference || (horizontalFrame != .referenceContainer && verticalFrame != .referenceContainer),
              let horizontalRule = parseHorizontalRule(horizontal.object("rule")),
              let verticalRule = parseVerticalRule(vertical.object("rule"))
        else { return nil }
        return TargetGeometryModelV1(
            horizontal: HorizontalAxisModelV1(frame: horizontalFrame, rule: horizontalRule),
            vertical: VerticalAxisModelV1(frame: verticalFrame, rule: verticalRule)
        )
    }

    private static func parseHorizontalRule(_ json: [String: Any]?) -> HorizontalRuleV1? {
        guard let json else { return nil }
        func nonNegative(_ key: String) -> Double? {
            json.strictDouble(key).flatMap { $0 >= 0 ? $0 : nil }
        }
        func positive(_ key: String) -> Double? {
            json.strictDouble(key).flatMap { $0 > 0 ? $0 : nil }
        }
        switch json.string("kind") {
        case "startFixed":
            guard let offset = nonNegative("startOffset"), let width = positive("width") else { return nil }
            return .startFixed(startOffset: offset, width: width)
        case "endFixed":
            guard let offset = nonNegative("endOffset"), let width = positive("width") else { return nil }
            return .endFixed(endOffset: offset, width: width)
        case "centerFixed":
            guard let offset = json.strictDouble("centerOffset"), let width = positive("width") else { return nil }
            return .centerFixed(centerOffset: offset, width: width)
        case "stretch":
            guard let start = nonNegative("startInset"), let end = nonNegative("endInset") else { return nil }
            return .stretch(startInset: start, endInset: end)
        case "proportional":
            guard let start = nonNegative("startFraction"), let end = json.strictDouble("endFraction"),
                  end > start, end <= 1 else { return nil }
            return .proportional(startFraction: start, endFraction: end)
        default: return nil
        }
    }

    private static func parseVerticalRule(_ json: [String: Any]?) -> VerticalRuleV1? {
        guard let json else { return nil }
        func nonNegative(_ key: String) -> Double? {
            json.strictDouble(key).flatMap { $0 >= 0 ? $0 : nil }
        }
        func positive(_ key: String) -> Double? {
            json.strictDouble(key).flatMap { $0 > 0 ? $0 : nil }
        }
        switch json.string("kind") {
        case "topFixed":
            guard let offset = nonNegative("topOffset"), let height = positive("height") else { return nil }
            return .topFixed(topOffset: offset, height: height)
        case "bottomFixed":
            guard let offset = nonNegative("bottomOffset"), let height = positive("height") else { return nil }
            return .bottomFixed(bottomOffset: offset, height: height)
        case "centerFixed":
            guard let offset = json.strictDouble("centerOffset"), let height = positive("height") else { return nil }
            return .centerFixed(centerOffset: offset, height: height)
        case "stretch":
            guard let top = nonNegative("topInset"), let bottom = nonNegative("bottomInset") else { return nil }
            return .stretch(topInset: top, bottomInset: bottom)
        case "proportional":
            guard let top = nonNegative("topFraction"), let bottom = json.strictDouble("bottomFraction"),
                  bottom > top, bottom <= 1 else { return nil }
            return .proportional(topFraction: top, bottomFraction: bottom)
        default: return nil
        }
    }

    private static func rejected(
        _ campaignKey: String?, _ failure: AssistedFailure, stepId: String? = nil
    ) -> AssistedPreparation {
        let trace = AssistedGeometryTraceV1(
            outcome: "failed", campaignKey: campaignKey, stepId: stepId,
            variantId: nil, captureId: nil, warnings: [], failure: failure,
            roundedTargetPx: nil
        )
        diagnostics.append(trace)
        return .rejected(failure, trace)
    }

    private static func failed(
        _ campaignKey: String?, _ step: PreparedAssistedStepV1?, _ failure: AssistedFailure
    ) -> AssistedResolution {
        let trace = AssistedGeometryTraceV1(
            outcome: "failed", campaignKey: campaignKey, stepId: step?.stepId,
            variantId: step?.variantId, captureId: step?.captureId, warnings: [],
            failure: failure, roundedTargetPx: nil
        )
        diagnostics.append(trace)
        return .failed(failure, trace)
    }

    private static func isUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value.lowercased()
    }

    private struct ParsedSource {
        let stepId: String
        let variantId: String
        let captureId: String
        let pageKey: String
        let density: Double
        let window: EdgeRectV1
        let content: EdgeRectV1
        let layoutDirection: String
        let comparison: AssistedComparisonContextV1
    }
}

private extension Dictionary where Key == String, Value == Any {
    func strictDouble(_ key: String) -> Double? {
        guard let number = self[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
}
