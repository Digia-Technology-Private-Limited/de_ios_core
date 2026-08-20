import Foundation

// Ported from Android `WidgetConfig.kt`. Colors are kept as hex strings (the
// rendering layer resolves them), so these models stay free of UIKit/SwiftUI.

enum GuideActionType: String {
    case dismiss = "DISMISS"
    case next = "NEXT"
    case prev = "PREV"

    static func parse(_ value: String?) -> GuideActionType {
        guard let value, let parsed = GuideActionType(rawValue: value.uppercased()) else {
            return .dismiss
        }
        return parsed
    }
}

struct GuideAction: Equatable {
    let id: String
    let label: String
    let style: String          // "filled" | "ghost"
    let actionType: GuideActionType
    let backgroundColor: String
    let textColor: String
    let fontSize: Double
    let fontWeight: Int
    let cornerRadius: Double
    let actions: [EngageAction]
}

struct ArrowConfig: Equatable {
    let visible: Bool
    let preferredDirection: String // "top"|"bottom"|"start"|"end"|"auto"
    let size: Int
    let color: String
}

struct BubbleConfig: Equatable {
    let backgroundColor: String
    let borderColor: String
    let borderWidth: Double
    let cornerRadius: Double
    let paddingHorizontal: Double
    let paddingVertical: Double
    let maxWidthDp: Double
    let elevation: Double
    let calloutGap: Double
    let entranceAnimation: String // "elastic"|"circular"|"fade"|"overshoot"|"none"
    let arrow: ArrowConfig
}

struct CutoutConfig: Equatable {
    let shape: String          // "rounded_rect"|"rect"|"circle"
    let cornerRadius: Double
    let padding: Double
    let glowColor: String
    let glowWidth: Double
}

struct OverlayConfig: Equatable {
    let visible: Bool          // false = tooltip, true = spotlight
    let color: String
    let alpha: Double
    let dismissOnTap: Bool
    let entranceAnimation: String // "fade"|"none"
    let cutout: CutoutConfig
}

struct GuideTextContent: Equatable {
    let text: String
    let fontWeight: Int
    let fontSize: Double
    let textColor: String
}

struct StepIndicatorConfig: Equatable {
    let visible: Bool
    let color: String
    let fontWeight: Int
}

struct GuideContentConfig: Equatable {
    let title: GuideTextContent?
    let body: GuideTextContent?
    let mediaUrl: String?
    let stepIndicator: StepIndicatorConfig
}

struct GuideStepWidgetConfig: Equatable {
    let bubble: BubbleConfig
    let overlay: OverlayConfig
    let content: GuideContentConfig
    let actions: [GuideAction]
    let layoutMode: String
    let canvas: CampaignCanvas?

    // Defaults (hex strings, matching Android's parsed-color fallbacks).
    private static let defaultBubbleBackground = "#1E40AF"
    private static let defaultArrowColor = "#1E40AF"
    private static let defaultOverlayColor = "#000000"
    private static let defaultStepColor = "#AAFFFFFF"
    private static let defaultButtonBackground = "#FFFFFF"
    private static let defaultButtonText = "#1E40AF"
    private static let defaultBodyColor = "#CCFFFFFF"
    private static let defaultTitleColor = "#FFFFFF"

    static func fromJson(
        _ json: [String: Any],
        designTokens: DesignTokenCatalog = .empty
    ) -> GuideStepWidgetConfig {
        let isFlatSpotlight = json.object("target")?.string("type") == "anchorless"
        let bubbleObj = json.object("bubble") ?? [:]
        let overlayObj = json.object("overlay") ?? [:]
        let contentObj = json.object("content") ?? [:]

        let arrowObj = bubbleObj.object("arrow") ?? [:]
        let calloutBackground = color(
            json.string("calloutBackgroundColor"),
            default: "#FFFFFF"
        )
        let arrow = ArrowConfig(
            visible: isFlatSpotlight
                ? json.bool("showArrow", default: true)
                : arrowObj.bool("visible", default: true),
            preferredDirection: isFlatSpotlight
                ? json.string("calloutPosition", default: "below")
                : arrowObj.string("preferred_direction", default: "auto"),
            size: isFlatSpotlight
                ? json.int("arrowSize", default: 8)
                : arrowObj.int("size", default: 10),
            color: isFlatSpotlight
                ? color(json.string("arrowColor"), default: calloutBackground)
                : color(arrowObj.string("color"), default: defaultArrowColor)
        )

        let bubble = BubbleConfig(
            backgroundColor: isFlatSpotlight
                ? calloutBackground
                : color(bubbleObj.string("background_color"), default: defaultBubbleBackground),
            borderColor: isFlatSpotlight
                ? color(json.string("calloutBorderColor"), default: "#00000000")
                : color(bubbleObj.string("border_color"), default: "#00000000"),
            borderWidth: nonNegative(
                isFlatSpotlight
                    ? json.double("calloutBorderWidth", default: 0)
                    : bubbleObj.double("border_width", default: 0),
                fallback: 0
            ),
            cornerRadius: nonNegative(
                isFlatSpotlight
                    ? json.double("calloutCornerRadius", default: 8)
                    : bubbleObj.double("corner_radius", default: 12),
                fallback: isFlatSpotlight ? 8 : 12
            ),
            paddingHorizontal: nonNegative(
                isFlatSpotlight
                    ? json.double("calloutPadding", default: 12)
                    : bubbleObj.double("padding_horizontal", default: 16),
                fallback: isFlatSpotlight ? 12 : 16
            ),
            paddingVertical: nonNegative(
                isFlatSpotlight
                    ? json.double("calloutPadding", default: 12)
                    : bubbleObj.double("padding_vertical", default: 12),
                fallback: 12
            ),
            maxWidthDp: positive(
                isFlatSpotlight
                    ? json.double("calloutMaxWidth", default: 280)
                    : bubbleObj.double("max_width", default: 280),
                fallback: 280
            ),
            elevation: nonNegative(
                isFlatSpotlight
                    ? (json.bool("calloutShadow", default: true) ? 6 : 0)
                    : bubbleObj.double("elevation", default: 6),
                fallback: 6
            ),
            calloutGap: nonNegative(
                isFlatSpotlight
                    ? json.double("calloutGap", default: 8)
                    : bubbleObj.double("callout_gap", default: 8),
                fallback: 8
            ),
            entranceAnimation: bubbleObj.string("entrance_animation", default: "elastic"),
            arrow: arrow
        )

        let cutoutObj = overlayObj.object("cutout") ?? [:]
        let cutout = CutoutConfig(
            shape: isFlatSpotlight
                ? json.string("highlightShape", default: "rect")
                : cutoutObj.string("shape", default: "rounded_rect"),
            cornerRadius: nonNegative(
                isFlatSpotlight
                    ? json.double("highlightCornerRadius", default: 8)
                    : cutoutObj.double("corner_radius", default: 12),
                fallback: isFlatSpotlight ? 8 : 12
            ),
            padding: nonNegative(
                isFlatSpotlight
                    ? json.double("highlightPadding", default: 8)
                    : cutoutObj.double("padding", default: 8),
                fallback: 8
            ),
            glowColor: isFlatSpotlight
                ? color(json.string("highlightGlowColor"), default: "#00000000")
                : color(cutoutObj.string("glow_color"), default: "#00000000"),
            glowWidth: nonNegative(
                isFlatSpotlight
                    ? json.double("highlightGlowWidth", default: 0)
                    : cutoutObj.double("glow_width", default: 0),
                fallback: 0
            )
        )

        let overlay = OverlayConfig(
            visible: isFlatSpotlight || overlayObj.bool("visible", default: false),
            color: isFlatSpotlight
                ? color(json.string("overlayColor"), default: defaultOverlayColor)
                : color(overlayObj.string("color"), default: defaultOverlayColor),
            alpha: bounded(
                isFlatSpotlight
                    ? 1
                    : overlayObj.double("alpha", default: 0.6),
                lower: 0,
                upper: 1,
                fallback: isFlatSpotlight ? 0.7 : 0.6
            ),
            dismissOnTap: isFlatSpotlight
                ? json.string("outsideTapBehavior", default: "next") != "nothing"
                : overlayObj.bool("dismiss_on_tap", default: false),
            entranceAnimation: overlayObj.string("entrance_animation", default: "fade"),
            cutout: cutout
        )

        let titleObj = contentObj.object("title")
        let bodyObj = contentObj.object("body")
        let mediaObj = contentObj.object("media")
        let stepIndObj = contentObj.object("step_indicator") ?? [:]

        let title = nestedText(titleObj, defaultWeight: 700, defaultSize: 16,
                               defaultColor: defaultTitleColor)
            ?? flatText(json, key: "title", defaultWeight: 700, defaultSize: 16,
                        defaultColor: defaultTitleColor)
        let body = nestedText(bodyObj, defaultWeight: 400, defaultSize: 14,
                              defaultColor: defaultBodyColor)
            ?? flatText(json, key: "body", defaultWeight: 400, defaultSize: 14,
                        defaultColor: defaultBodyColor)

        let content = GuideContentConfig(
            title: title,
            body: body,
            mediaUrl: mediaObj?.nonBlankString("url"),
            stepIndicator: StepIndicatorConfig(
                visible: stepIndObj.bool("visible", default: false),
                color: color(stepIndObj.string("color"), default: defaultStepColor),
                fontWeight: DigiaFontWeight.value(stepIndObj["fontWeight"], default: 400)
            )
        )

        let actionsArr = (json["actions"] as? [Any])
            ?? (contentObj["actions"] as? [Any])
            ?? []
        var actions: [GuideAction] = []
        for (index, element) in actionsArr.enumerated() {
            guard let obj = element as? [String: Any] else { continue }
            let typeStr = obj.nonBlankString("action_type")
                ?? obj.string("type", default: "dismiss")
            let actionType = GuideActionType.parse(typeStr)
            let style = obj.string("style", default: "filled")
            let isPrimary = style == "filled" || style == "primary"
            let defaultBackground = isPrimary
                ? color(json.string("buttonPrimaryBackgroundColor"), default: defaultButtonBackground)
                : "#00000000"
            let defaultText = color(
                json.string(isPrimary ? "buttonPrimaryTextColor" : "buttonGhostTextColor"),
                default: defaultButtonText
            )
            let onClick = obj.object("onClick")
            let legacyAction: EngageAction = switch typeStr.lowercased() {
            case "next": .next
            case "prev", "back", "previous": .previous
            case "open_url": obj.nonBlankString("url").map(EngageAction.openUrl) ?? .dismiss
            case "deep_link", "deeplink": obj.nonBlankString("url").map(EngageAction.openDeeplink) ?? .dismiss
            default: .dismiss
            }
            actions.append(
                GuideAction(
                    id: obj.string("id", default: "btn_\(index)"),
                    label: obj.string("label"),
                    style: style,
                    actionType: actionType,
                    backgroundColor: obj.nonBlankString("background_color")
                        .map { color($0, default: defaultButtonBackground) }
                        ?? defaultBackground,
                    textColor: obj.nonBlankString("text_color")
                        .map { color($0, default: defaultButtonText) }
                        ?? defaultText,
                    fontSize: positive(obj.double("fontSize", default: 14), fallback: 14),
                    fontWeight: DigiaFontWeight.value(obj["fontWeight"], default: 600),
                    cornerRadius: nonNegative(
                        obj.double("corner_radius", default: 8),
                        fallback: 8
                    ),
                    actions: onClick.map { EngageActionParser().parse($0) } ?? [legacyAction]
                )
            )
        }

        let layoutMode = json.string("layoutMode", default: "classic")
        let canvas = isFlatSpotlight && layoutMode == "canvas"
            ? (json.object("canvas").flatMap {
                try? CampaignCanvasParser(designTokens: designTokens).parse($0)
            })
            : nil
        return GuideStepWidgetConfig(
            bubble: bubble,
            overlay: overlay,
            content: content,
            actions: actions,
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

    private static func positive(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }

    private static func bounded(
        _ value: Double,
        lower: Double,
        upper: Double,
        fallback: Double
    ) -> Double {
        value.isFinite ? min(max(value, lower), upper) : fallback
    }

    private static func nestedText(
        _ json: [String: Any]?,
        defaultWeight: Int,
        defaultSize: Double,
        defaultColor: String
    ) -> GuideTextContent? {
        guard let json, let text = json.nonBlankString("text") else { return nil }
        let style = json.object("textStyle") ?? [:]
        let font = style.object("fontToken")?.object("font") ?? [:]
        return GuideTextContent(
            text: text,
            fontWeight: DigiaFontWeight.value(font["weight"], default: defaultWeight),
            fontSize: positive(font.double("size", default: defaultSize), fallback: defaultSize),
            textColor: color(style.string("textColor"), default: defaultColor)
        )
    }

    private static func flatText(
        _ json: [String: Any],
        key: String,
        defaultWeight: Int,
        defaultSize: Double,
        defaultColor: String
    ) -> GuideTextContent? {
        guard let text = json.nonBlankString(key) else { return nil }
        return GuideTextContent(
            text: text,
            fontWeight: DigiaFontWeight.value(json["\(key)Weight"], default: defaultWeight),
            fontSize: positive(json.double("\(key)Size", default: defaultSize), fallback: defaultSize),
            textColor: color(json.string("\(key)Color"), default: defaultColor)
        )
    }
}
