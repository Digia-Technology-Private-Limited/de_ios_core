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
    let cornerRadius: Double
    let paddingHorizontal: Double
    let paddingVertical: Double
    let maxWidthDp: Double
    let elevation: Double
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
        let bubbleObj = json.object("bubble") ?? [:]
        let overlayObj = json.object("overlay") ?? [:]
        let contentObj = json.object("content") ?? [:]

        let arrowObj = bubbleObj.object("arrow") ?? [:]
        let arrow = ArrowConfig(
            visible: arrowObj["visible"] != nil
                ? arrowObj.bool("visible", default: true)
                : json.bool("showArrow", default: true),
            preferredDirection: arrowObj.nonBlankString("preferred_direction")
                ?? flatArrowDirection(json.string("calloutPosition", default: "auto")),
            size: arrowObj["size"] != nil
                ? arrowObj.int("size", default: 10)
                : json.int("arrowSize", default: 10),
            color: color(
                arrowObj.nonBlankString("color") ?? json.nonBlankString("arrowColor"),
                default: json.string("calloutBackgroundColor", default: defaultArrowColor)
            )
        )

        let bubble = BubbleConfig(
            backgroundColor: color(
                bubbleObj.nonBlankString("background_color")
                    ?? json.nonBlankString("calloutBackgroundColor"),
                default: defaultBubbleBackground
            ),
            cornerRadius: bubbleObj["corner_radius"] != nil
                ? bubbleObj.double("corner_radius", default: 12)
                : json.double("calloutCornerRadius", default: 12),
            paddingHorizontal: bubbleObj["padding_horizontal"] != nil
                ? bubbleObj.double("padding_horizontal", default: 16)
                : json.double("calloutPadding", default: 16),
            paddingVertical: bubbleObj["padding_vertical"] != nil
                ? bubbleObj.double("padding_vertical", default: 12)
                : json.double("calloutPadding", default: 16),
            maxWidthDp: bubbleObj["max_width"] != nil
                ? bubbleObj.double("max_width", default: 280)
                : json.double("calloutMaxWidth", default: 280),
            elevation: bubbleObj["elevation"] != nil
                ? bubbleObj.double("elevation", default: 6)
                : (json.bool("calloutShadow", default: true) ? 6 : 0),
            entranceAnimation: bubbleObj.string("entrance_animation", default: "elastic"),
            arrow: arrow
        )

        let cutoutObj = overlayObj.object("cutout") ?? [:]
        let cutout = CutoutConfig(
            shape: cutoutObj.nonBlankString("shape")
                ?? json.string("highlightShape", default: "rounded_rect"),
            cornerRadius: cutoutObj["corner_radius"] != nil
                ? cutoutObj.double("corner_radius", default: 12)
                : json.double("highlightCornerRadius", default: 12),
            padding: cutoutObj["padding"] != nil
                ? cutoutObj.double("padding", default: 8)
                : json.double("highlightPadding", default: 8),
            glowColor: color(
                cutoutObj.nonBlankString("glow_color")
                    ?? json.nonBlankString("highlightGlowColor"),
                default: "#4945FF"
            ),
            glowWidth: cutoutObj["glow_width"] != nil
                ? cutoutObj.double("glow_width", default: 0)
                : json.double("highlightGlowWidth", default: 0)
        )

        let overlay = OverlayConfig(
            visible: overlayObj["visible"] != nil
                ? overlayObj.bool("visible", default: false)
                : json["overlayColor"] != nil || json["highlightShape"] != nil,
            color: color(
                overlayObj.nonBlankString("color") ?? json.nonBlankString("overlayColor"),
                default: defaultOverlayColor
            ),
            alpha: overlayObj["alpha"] != nil
                ? overlayObj.double("alpha", default: 0.6)
                : json.double("overlayOpacity", default: 0.6),
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
                    fontSize: max(1, obj.double("fontSize", default: 14)),
                    fontWeight: DigiaFontWeight.value(obj["fontWeight"], default: 600),
                    cornerRadius: obj["corner_radius"] == nil
                        ? 8
                        : obj.double("corner_radius", default: 8),
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

    private static func flatArrowDirection(_ placement: String) -> String {
        switch placement {
        case "above": return "bottom"
        case "below": return "top"
        case "left": return "end"
        case "right": return "start"
        default: return "auto"
        }
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
