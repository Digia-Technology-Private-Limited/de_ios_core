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
    let padding: GuideInsets
    let margin: GuideInsets
    let actions: [EngageAction]
}

struct GuideInsets: Equatable {
    let top: Double
    let right: Double
    let bottom: Double
    let left: Double
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

    // Defaults (hex strings, matching Android's parsed-color fallbacks).
    private static let defaultBubbleBackground = "#1E40AF"
    private static let defaultArrowColor = "#1E40AF"
    private static let defaultOverlayColor = "#000000"
    private static let defaultStepColor = "#AAFFFFFF"
    private static let defaultButtonBackground = "#FFFFFF"
    private static let defaultButtonText = "#1E40AF"
    private static let defaultBodyColor = "#CCFFFFFF"
    private static let defaultTitleColor = "#FFFFFF"

    static func fromJson(_ json: [String: Any]) -> GuideStepWidgetConfig {
        let isFlatSpotlight = json["overlayColor"] != nil || json["calloutBackgroundColor"] != nil
        let bubbleObj = json.object("bubble") ?? [:]
        let overlayObj = json.object("overlay") ?? [:]
        let contentObj = json.object("content") ?? [:]

        let arrowObj = bubbleObj.object("arrow") ?? [:]
        let calloutBackground = color(
            json.string("calloutBackgroundColor"),
            default: defaultBubbleBackground
        )
        let arrow = ArrowConfig(
            visible: isFlatSpotlight
                ? json.bool("showArrow", default: true)
                : arrowObj.bool("visible", default: true),
            preferredDirection: isFlatSpotlight
                ? json.string("calloutPosition", default: "auto")
                : arrowObj.string("preferred_direction", default: "auto"),
            size: isFlatSpotlight
                ? json.int("arrowSize", default: 8)
                : arrowObj.int("size", default: 10),
            color: isFlatSpotlight
                ? calloutBackground
                : color(arrowObj.string("color"), default: defaultArrowColor)
        )

        let bubble = BubbleConfig(
            backgroundColor: isFlatSpotlight
                ? calloutBackground
                : color(bubbleObj.string("background_color"), default: defaultBubbleBackground),
            borderColor: isFlatSpotlight
                ? color(json.string("calloutBorderColor"), default: "#00000000")
                : color(bubbleObj.string("border_color"), default: "#00000000"),
            borderWidth: isFlatSpotlight
                ? json.double("calloutBorderWidth", default: 0)
                : bubbleObj.double("border_width", default: 0),
            cornerRadius: isFlatSpotlight
                ? json.double("calloutCornerRadius", default: 12)
                : bubbleObj.double("corner_radius", default: 12),
            paddingHorizontal: isFlatSpotlight
                ? json.double("calloutPadding", default: 16)
                : bubbleObj.double("padding_horizontal", default: 16),
            paddingVertical: isFlatSpotlight
                ? json.double("calloutPadding", default: 16)
                : bubbleObj.double("padding_vertical", default: 12),
            maxWidthDp: isFlatSpotlight
                ? json.double("calloutMaxWidth", default: 280)
                : bubbleObj.double("max_width", default: 280),
            elevation: isFlatSpotlight
                ? (json.bool("calloutShadow", default: true) ? 6 : 0)
                : bubbleObj.double("elevation", default: 6),
            calloutGap: isFlatSpotlight
                ? json.double("calloutGap", default: 8)
                : bubbleObj.double("callout_gap", default: 8),
            entranceAnimation: bubbleObj.string("entrance_animation", default: "elastic"),
            arrow: arrow
        )

        let cutoutObj = overlayObj.object("cutout") ?? [:]
        let cutout = CutoutConfig(
            shape: isFlatSpotlight
                ? json.string("highlightShape", default: "rect")
                : cutoutObj.string("shape", default: "rounded_rect"),
            cornerRadius: isFlatSpotlight
                ? json.double("highlightCornerRadius", default: 12)
                : cutoutObj.double("corner_radius", default: 12),
            padding: isFlatSpotlight
                ? json.double("highlightPadding", default: 8)
                : cutoutObj.double("padding", default: 8),
            glowColor: isFlatSpotlight
                ? color(json.string("highlightGlowColor"), default: "#00000000")
                : color(cutoutObj.string("glow_color"), default: "#00000000"),
            glowWidth: isFlatSpotlight
                ? json.double("highlightGlowWidth", default: 0)
                : cutoutObj.double("glow_width", default: 0)
        )

        let overlay = OverlayConfig(
            visible: isFlatSpotlight || overlayObj.bool("visible", default: false),
            color: isFlatSpotlight
                ? color(json.string("overlayColor"), default: defaultOverlayColor)
                : color(overlayObj.string("color"), default: defaultOverlayColor),
            alpha: isFlatSpotlight
                ? json.double("overlayOpacity", default: 0.6)
                : overlayObj.double("alpha", default: 0.6),
            dismissOnTap: overlayObj.bool("dismiss_on_tap", default: false),
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
            let style = switch obj.string("style", default: "fill") {
            case "primary": "fill"
            case "secondary": "outline"
            case "ghost": "text"
            case let value: value
            }
            let isPrimary = style == "fill" || style == "filled" || style == "elevated"
            let defaultBackground = isPrimary
                ? color(json.string("buttonPrimaryBackgroundColor"), default: defaultButtonBackground)
                : "#00000000"
            let defaultText = color(
                json.string(isPrimary ? "buttonPrimaryTextColor" : "buttonGhostTextColor"),
                default: defaultButtonText
            )
            let onClick = obj.object("onClick")
            let padding = obj.object("padding") ?? [:]
            let margin = obj.object("margin") ?? [:]
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
                    backgroundColor: (obj.nonBlankString("backgroundColor")
                        ?? obj.nonBlankString("background_color"))
                        .map { color($0, default: defaultButtonBackground) }
                        ?? defaultBackground,
                    textColor: (obj.nonBlankString("textColor")
                        ?? obj.nonBlankString("text_color"))
                        .map { color($0, default: defaultButtonText) }
                        ?? defaultText,
                    fontSize: max(1, obj.double("fontSize", default: 14)),
                    fontWeight: DigiaFontWeight.value(obj["fontWeight"], default: 600),
                    cornerRadius: obj["cornerRadius"] != nil
                        ? obj.double("cornerRadius", default: 8)
                        : obj.double("corner_radius", default: 8),
                    padding: GuideInsets(
                        top: padding.double("top", default: 8),
                        right: padding.double("right", default: 12),
                        bottom: padding.double("bottom", default: 8),
                        left: padding.double("left", default: 12)
                    ),
                    margin: GuideInsets(
                        top: margin.double("top", default: 0),
                        right: margin.double("right", default: 0),
                        bottom: margin.double("bottom", default: 0),
                        left: margin.double("left", default: index > 0 ? 8 : 0)
                    ),
                    actions: onClick.map { EngageActionParser().parse($0) } ?? [legacyAction]
                )
            )
        }

        return GuideStepWidgetConfig(bubble: bubble, overlay: overlay, content: content, actions: actions)
    }

    private static func color(_ value: String?, default fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
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
            fontSize: font.double("size", default: defaultSize),
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
            fontSize: json.double("\(key)Size", default: defaultSize),
            textColor: color(json.string("\(key)Color"), default: defaultColor)
        )
    }
}
