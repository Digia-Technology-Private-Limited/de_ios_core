import Foundation

enum GuideOutsideTapBehavior: String, Equatable {
    case next
    case nothing
}

struct ArrowConfig: Equatable {
    let visible: Bool
    let preferredDirection: String
    let size: Int
}

struct BubbleConfig: Equatable {
    let borderColor: String
    let borderWidth: Double
    let cornerRadius: Double
    let elevation: Double
    let calloutGap: Double
    let arrow: ArrowConfig
}

struct CutoutConfig: Equatable {
    let shape: String
    let cornerRadius: Double
    let padding: Double
    let glowColor: String
    let glowWidth: Double
}

struct OverlayConfig: Equatable {
    let visible: Bool
    let color: String
    let alpha: Double
    let cutout: CutoutConfig
}

struct GuideStepWidgetConfig: Equatable {
    let bubble: BubbleConfig
    let overlay: OverlayConfig
    let outsideTapBehavior: GuideOutsideTapBehavior
    let layoutMode: String
    let canvas: CampaignCanvas?

    static func fromJson(
        _ json: [String: Any],
        displayStyle: String? = nil,
        designTokens: DesignTokenCatalog = .empty
    ) -> GuideStepWidgetConfig {
        let isSpotlight = displayStyle == "spotlight"
            || json.object("target")?.string("type") == "anchorless"
            || json["calloutPosition"] != nil
            || json["highlightShape"] != nil
        let layoutMode = json.string("layoutMode", default: "classic")
        let arrow = ArrowConfig(
            visible: json.bool("showArrow", default: true),
            preferredDirection: json.string(isSpotlight ? "calloutPosition" : "placement", default: "bottom"),
            size: min(40, max(0, json.int("arrowSize", default: 8)))
        )
        let bubble = BubbleConfig(
            borderColor: color(json.string(isSpotlight ? "calloutBorderColor" : "borderColor"), default: "#00000000"),
            borderWidth: nonNegative(json.double(isSpotlight ? "calloutBorderWidth" : "borderWidth", default: 0), fallback: 0),
            cornerRadius: nonNegative(json.double(isSpotlight ? "calloutCornerRadius" : "cornerRadius", default: 8), fallback: 8),
            elevation: json.bool(isSpotlight ? "calloutShadow" : "shadow", default: true) ? 8 : 0,
            calloutGap: nonNegative(json.double(isSpotlight ? "calloutGap" : "gap", default: isSpotlight ? 8 : 12), fallback: 8),
            arrow: arrow
        )
        let cutout = CutoutConfig(
            shape: json.string("highlightShape", default: "rect"),
            cornerRadius: nonNegative(json.double("highlightCornerRadius", default: 8), fallback: 8),
            padding: nonNegative(json.double("highlightPadding", default: 8), fallback: 8),
            glowColor: color(json.string("highlightGlowColor"), default: "#00000000"),
            glowWidth: nonNegative(json.double("highlightGlowWidth", default: 0), fallback: 0)
        )
        let overlay = OverlayConfig(
            visible: isSpotlight,
            color: color(json.string("overlayColor"), default: "#000000"),
            alpha: bounded(json.double("overlayOpacity", default: 0.7), lower: 0, upper: 1, fallback: 0.7),
            cutout: cutout
        )
        let canvas = layoutMode == "canvas"
            ? json.object("canvas").flatMap { try? CampaignCanvasParser(designTokens: designTokens).parse($0) }
            : nil
        return GuideStepWidgetConfig(
            bubble: bubble,
            overlay: overlay,
            outsideTapBehavior: GuideOutsideTapBehavior(
                rawValue: json.string("outsideTapBehavior", default: "next")
            ) ?? .next,
            layoutMode: layoutMode,
            canvas: canvas
        )
    }

    private static func color(_ value: String?, default fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }

    private static func nonNegative(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? max(0, value) : fallback
    }

    private static func bounded(_ value: Double, lower: Double, upper: Double, fallback: Double) -> Double {
        value.isFinite ? min(max(value, lower), upper) : fallback
    }
}
