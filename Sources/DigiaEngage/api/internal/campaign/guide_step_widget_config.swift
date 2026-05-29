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
    let cornerRadius: Double
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
    let fontFamily: String
    let fontWeight: String
    let fontSize: Double
    let textColor: String
}

struct StepIndicatorConfig: Equatable {
    let visible: Bool
    let color: String
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
    private static let defaultStepColor = "#FFFFFFAA"
    private static let defaultButtonBackground = "#FFFFFF"
    private static let defaultButtonText = "#1E40AF"
    private static let defaultBodyColor = "#FFFFFFCC"
    private static let defaultTitleColor = "#FFFFFF"

    static func fromJson(_ json: [String: Any]) -> GuideStepWidgetConfig {
        let bubbleObj = json.object("bubble") ?? [:]
        let overlayObj = json.object("overlay") ?? [:]
        let contentObj = json.object("content") ?? [:]

        let arrowObj = bubbleObj.object("arrow") ?? [:]
        let arrow = ArrowConfig(
            visible: arrowObj.bool("visible", default: true),
            preferredDirection: arrowObj.string("preferred_direction", default: "auto"),
            size: arrowObj.int("size", default: 10),
            color: color(arrowObj.string("color"), default: defaultArrowColor)
        )

        let bubble = BubbleConfig(
            backgroundColor: color(bubbleObj.string("background_color"), default: defaultBubbleBackground),
            cornerRadius: bubbleObj.double("corner_radius", default: 12),
            paddingHorizontal: bubbleObj.double("padding_horizontal", default: 16),
            paddingVertical: bubbleObj.double("padding_vertical", default: 12),
            maxWidthDp: bubbleObj.double("max_width", default: 280),
            elevation: bubbleObj.double("elevation", default: 6),
            entranceAnimation: bubbleObj.string("entrance_animation", default: "elastic"),
            arrow: arrow
        )

        let cutoutObj = overlayObj.object("cutout") ?? [:]
        let cutout = CutoutConfig(
            shape: cutoutObj.string("shape", default: "rounded_rect"),
            cornerRadius: cutoutObj.double("corner_radius", default: 12),
            padding: cutoutObj.double("padding", default: 8)
        )

        let overlay = OverlayConfig(
            visible: overlayObj.bool("visible", default: false),
            color: color(overlayObj.string("color"), default: defaultOverlayColor),
            alpha: overlayObj.double("alpha", default: 0.6),
            dismissOnTap: overlayObj.bool("dismiss_on_tap", default: false),
            entranceAnimation: overlayObj.string("entrance_animation", default: "fade"),
            cutout: cutout
        )

        let titleObj = contentObj.object("title")
        let bodyObj = contentObj.object("body")
        let mediaObj = contentObj.object("media")
        let stepIndObj = contentObj.object("step_indicator") ?? [:]

        // Support legacy flat schema: "title"/"body" as top-level strings.
        let titleText = titleObj?.nonBlankString("text") ?? json.nonBlankString("title")
        let bodyText = bodyObj?.nonBlankString("text") ?? json.nonBlankString("body")

        let title = titleText.map { text -> GuideTextContent in
            let style = titleObj?.object("textStyle") ?? [:]
            let font = (style.object("fontToken")?.object("font")) ?? [:]
            return GuideTextContent(
                text: text,
                fontFamily: font.string("fontFamily"),
                fontWeight: font.string("weight", default: "bold"),
                fontSize: font.double("size", default: 16),
                textColor: color(style.string("textColor"), default: defaultTitleColor)
            )
        }

        let body = bodyText.map { text -> GuideTextContent in
            let style = bodyObj?.object("textStyle") ?? [:]
            let font = (style.object("fontToken")?.object("font")) ?? [:]
            return GuideTextContent(
                text: text,
                fontFamily: font.string("fontFamily"),
                fontWeight: font.string("weight", default: "regular"),
                fontSize: font.double("size", default: 14),
                textColor: color(style.string("textColor"), default: defaultBodyColor)
            )
        }

        let content = GuideContentConfig(
            title: title,
            body: body,
            mediaUrl: mediaObj?.nonBlankString("url"),
            stepIndicator: StepIndicatorConfig(
                visible: stepIndObj.bool("visible", default: false),
                color: color(stepIndObj.string("color"), default: defaultStepColor)
            )
        )

        let actionsArr = (json["actions"] as? [Any]) ?? (contentObj["actions"] as? [Any]) ?? []
        var actions: [GuideAction] = []
        for (index, element) in actionsArr.enumerated() {
            guard let obj = element as? [String: Any] else { continue }
            // Support both "action_type" (new schema) and "type" (legacy).
            let typeStr = obj.nonBlankString("action_type") ?? obj.string("type", default: "dismiss")
            actions.append(
                GuideAction(
                    id: obj.string("id", default: "btn_\(index)"),
                    label: obj.string("label"),
                    style: obj.string("style", default: "filled"),
                    actionType: GuideActionType.parse(typeStr),
                    backgroundColor: color(obj.string("background_color"), default: defaultButtonBackground),
                    textColor: color(obj.string("text_color"), default: defaultButtonText),
                    cornerRadius: obj.double("corner_radius", default: 8)
                )
            )
        }

        return GuideStepWidgetConfig(bubble: bubble, overlay: overlay, content: content, actions: actions)
    }

    private static func color(_ value: String?, default fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }
}
