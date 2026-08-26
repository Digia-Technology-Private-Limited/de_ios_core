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

enum GuideWidgetSchema: Equatable {
    case nested
    case flat
}

enum GuideOutsideTapBehavior: String, Equatable {
    case next
    case nothing
}

struct GuideEdgeInsets: Equatable {
    let top: Double
    let right: Double
    let bottom: Double
    let left: Double
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
    let padding: GuideEdgeInsets
    let margin: GuideEdgeInsets
    let actions: [EngageAction]
    let fireEventName: String?
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
    let schema: GuideWidgetSchema
    let bubble: BubbleConfig
    let overlay: OverlayConfig
    let content: GuideContentConfig
    let actions: [GuideAction]
    let outsideTapBehavior: GuideOutsideTapBehavior
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
        schema: GuideWidgetSchema? = nil,
        displayStyle: String? = nil,
        designTokens: DesignTokenCatalog = .empty
    ) -> GuideStepWidgetConfig {
        let schema = schema ?? inferredSchema(json)
        let isFlat = schema == .flat
        let isFlatSpotlight = isFlat && (
            displayStyle == "spotlight"
                || json.object("target")?.string("type") == "anchorless"
                || json["calloutPosition"] != nil
                || json["highlightShape"] != nil
        )
        let isFlatTooltip = isFlat && !isFlatSpotlight
        let layoutMode = json.string("layoutMode", default: "classic")
        let usesCanvas = isFlat && layoutMode == "canvas"
        let bubbleObj = json.object("bubble") ?? [:]
        let overlayObj = json.object("overlay") ?? [:]
        let contentObj = json.object("content") ?? [:]

        let arrowObj = bubbleObj.object("arrow") ?? [:]
        let calloutBackground = color(
            json.string(isFlatSpotlight ? "calloutBackgroundColor" : "backgroundColor"),
            default: "#FFFFFF"
        )
        let arrow = ArrowConfig(
            visible: isFlat
                ? json.bool("showArrow", default: true)
                : arrowObj.bool("visible", default: true),
            preferredDirection: isFlat
                ? json.string(isFlatSpotlight ? "calloutPosition" : "placement", default: "bottom")
                : arrowObj.string("preferred_direction", default: "auto"),
            size: min(
                40,
                max(
                    0,
                    isFlat
                        ? json.int("arrowSize", default: 8)
                        : arrowObj.int("size", default: 10)
                )
            ),
            color: isFlat
                ? calloutBackground
                : color(arrowObj.string("color"), default: defaultArrowColor)
        )

        let bubble = BubbleConfig(
            backgroundColor: isFlat
                ? calloutBackground
                : color(bubbleObj.string("background_color"), default: defaultBubbleBackground),
            borderColor: isFlat
                ? color(
                    json.string(isFlatSpotlight ? "calloutBorderColor" : "borderColor"),
                    default: "#00000000"
                )
                : color(bubbleObj.string("border_color"), default: "#00000000"),
            borderWidth: nonNegative(
                isFlat
                    ? json.double(isFlatSpotlight ? "calloutBorderWidth" : "borderWidth", default: 0)
                    : bubbleObj.double("border_width", default: 0),
                fallback: 0
            ),
            cornerRadius: nonNegative(
                isFlat
                    ? json.double(isFlatSpotlight ? "calloutCornerRadius" : "cornerRadius", default: 8)
                    : bubbleObj.double("corner_radius", default: 12),
                fallback: isFlat ? 8 : 12
            ),
            paddingHorizontal: nonNegative(
                isFlat
                    ? json.double(isFlatSpotlight ? "calloutPadding" : "padding", default: 12)
                    : bubbleObj.double("padding_horizontal", default: 16),
                fallback: isFlat ? 12 : 16
            ),
            paddingVertical: nonNegative(
                isFlat
                    ? json.double(isFlatSpotlight ? "calloutPadding" : "padding", default: 12)
                    : bubbleObj.double("padding_vertical", default: 12),
                fallback: 12
            ),
            maxWidthDp: positive(
                isFlat
                    ? json.double(isFlatSpotlight ? "calloutMaxWidth" : "maxWidth", default: 280)
                    : bubbleObj.double("max_width", default: 280),
                fallback: 280
            ),
            elevation: nonNegative(
                isFlat
                    ? (json.bool(isFlatSpotlight ? "calloutShadow" : "shadow", default: true) ? 8 : 0)
                    : bubbleObj.double("elevation", default: 6),
                fallback: 6
            ),
            calloutGap: nonNegative(
                isFlatSpotlight
                    ? json.double("calloutGap", default: 8)
                        + (arrow.visible && !usesCanvas ? Double(arrow.size) : 0)
                    : isFlatTooltip
                        ? (usesCanvas
                            ? json.double("gap", default: 12)
                            : (arrow.visible ? Double(arrow.size) + 4 : 8))
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
                    ? json.double("overlayOpacity", default: 0.7)
                    : overlayObj.double("alpha", default: 0.6),
                lower: 0,
                upper: 1,
                fallback: isFlatSpotlight ? 0.7 : 0.6
            ),
            dismissOnTap: overlayObj.bool("dismiss_on_tap", default: false),
            entranceAnimation: overlayObj.string("entrance_animation", default: "fade"),
            cutout: cutout
        )

        let titleObj = contentObj.object("title")
        let bodyObj = contentObj.object("body")
        let mediaObj = contentObj.object("media")
        let stepIndObj = contentObj.object("step_indicator") ?? [:]

        let title = isFlat
            ? flatText(
                json,
                key: "title",
                defaultWeight: 700,
                defaultSize: 15,
                defaultColor: "#111111"
            )
            : (nestedText(
                titleObj,
                defaultWeight: 700,
                defaultSize: 16,
                defaultColor: defaultTitleColor
            ) ?? flatText(
                json,
                key: "title",
                defaultWeight: 700,
                defaultSize: 16,
                defaultColor: defaultTitleColor
            ))
        let body = isFlat
            ? flatText(
                json,
                key: "body",
                defaultWeight: 400,
                defaultSize: 13,
                defaultColor: "#444444"
            )
            : (nestedText(
                bodyObj,
                defaultWeight: 400,
                defaultSize: 14,
                defaultColor: defaultBodyColor
            ) ?? flatText(
                json,
                key: "body",
                defaultWeight: 400,
                defaultSize: 14,
                defaultColor: defaultBodyColor
            ))

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
            let style = isFlat
                ? buttonStyle(obj.string("style", default: "fill"))
                : obj.string("style", default: "filled")
            let isPrimary = isFlat
                ? style == "fill" || style == "elevated"
                : style == "filled" || style == "primary"
            let defaultBackground = isPrimary
                ? color(json.string("buttonPrimaryBackgroundColor"), default: isFlat ? "#4945FF" : defaultButtonBackground)
                : color(json.string("buttonGhostTextColor"), default: "#4945FF")
            let defaultText = color(
                json.string(isPrimary ? "buttonPrimaryTextColor" : "buttonGhostTextColor"),
                default: isFlat ? "#FFFFFF" : defaultButtonText
            )
            let onClick = obj.object("onClick")
            let canonicalActions = onClick.map { EngageActionParser().parse($0) } ?? []
            let legacyActions: [EngageAction] = switch typeStr.lowercased() {
            case "next": [.next]
            case "prev", "back", "previous": [.previous]
            case "open_url": legacyLinkActions(
                obj.nonBlankString("url").map {
                    .openUrl(
                        $0,
                        presentation: obj.nonBlankString("presentation") == "in_app"
                            || obj.nonBlankString("launchMode") == "inAppBrowser"
                            ? "in_app"
                            : nil
                    )
                },
                dismissAfterward: isFlat
            )
            case "deep_link", "deeplink": legacyLinkActions(
                obj.nonBlankString("url").map {
                    .openDeeplink(
                        $0,
                        fallbackUrl: obj.nonBlankString("fallbackUrl")
                            ?? obj.nonBlankString("fallback_url")
                    )
                },
                dismissAfterward: isFlat
            )
            case "copy" where isFlat:
                [obj.nonBlankString("text").map(EngageAction.copyToClipboard) ?? .dismiss]
            case "share" where isFlat:
                [obj.nonBlankString("text").map(EngageAction.share) ?? .dismiss]
            case "customkv" where isFlat: (obj["payload"] as? [String: Any]).flatMap { raw in
                let payload = raw.reduce(into: [String: String]()) { result, entry in
                    if let value = entry.value as? String { result[entry.key] = value }
                }
                return payload.isEmpty ? nil : .customKV(payload)
            }.map { [$0] } ?? [.dismiss]
            case "fire_event" where isFlat: []
            default: [.dismiss]
            }
            actions.append(
                GuideAction(
                    id: obj.string("id", default: "btn_\(index)"),
                    label: obj.string("label"),
                    style: style,
                    actionType: actionType,
                    backgroundColor: (isFlat
                        ? obj.nonBlankString("backgroundColor")
                        : obj.nonBlankString("background_color"))
                        .map { color($0, default: defaultButtonBackground) }
                        ?? defaultBackground,
                    textColor: (isFlat
                        ? obj.nonBlankString("textColor")
                        : obj.nonBlankString("text_color"))
                        .map { color($0, default: defaultButtonText) }
                        ?? defaultText,
                    fontSize: positive(
                        number(obj, "fontSize", "font_size", default: isFlat ? 13 : 14),
                        fallback: isFlat ? 13 : 14
                    ),
                    fontWeight: DigiaFontWeight.value(obj["fontWeight"], default: 600),
                    cornerRadius: nonNegative(
                        isFlat
                            ? number(obj, "cornerRadius", "corner_radius", default: 8)
                            : obj.double("corner_radius", default: 8),
                        fallback: 8
                    ),
                    padding: isFlat
                        ? edges(
                            obj["padding"],
                            fallback: GuideEdgeInsets(top: 8, right: 12, bottom: 8, left: 12)
                        )
                        : GuideEdgeInsets(top: 6, right: 12, bottom: 6, left: 12),
                    margin: isFlat
                        ? edges(
                            obj["margin"],
                            fallback: index == 0
                                ? GuideEdgeInsets(top: 0, right: 0, bottom: 0, left: 0)
                                : GuideEdgeInsets(top: 0, right: 0, bottom: 0, left: 8)
                        )
                        : GuideEdgeInsets(top: 0, right: 0, bottom: 0, left: 0),
                    actions: canonicalActions.isEmpty ? legacyActions : canonicalActions,
                    fireEventName: isFlat && canonicalActions.isEmpty
                        && typeStr.lowercased() == "fire_event"
                        ? obj.nonBlankString("event_name")
                        : nil
                )
            )
        }

        let canvas = isFlat && layoutMode == "canvas"
            ? (json.object("canvas").flatMap {
                try? CampaignCanvasParser(designTokens: designTokens).parse($0)
            })
            : nil
        return GuideStepWidgetConfig(
            schema: schema,
            bubble: bubble,
            overlay: overlay,
            content: content,
            actions: actions,
            outsideTapBehavior: GuideOutsideTapBehavior(
                rawValue: json.string("outsideTapBehavior", default: "next")
            ) ?? .next,
            layoutMode: layoutMode,
            canvas: canvas
        )
    }

    private static func inferredSchema(_ json: [String: Any]) -> GuideWidgetSchema {
        json["bubble"] != nil || json["overlay"] != nil || json["content"] != nil
            ? .nested
            : .flat
    }

    private static func legacyLinkActions(
        _ action: EngageAction?,
        dismissAfterward: Bool
    ) -> [EngageAction] {
        guard let action else { return [.dismiss] }
        return dismissAfterward ? [action, .dismiss] : [action]
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

    private static func buttonStyle(_ value: String) -> String {
        switch value.lowercased() {
        case "outline", "secondary": "outline"
        case "text", "ghost": "text"
        case "elevated": "elevated"
        default: "fill"
        }
    }

    private static func number(
        _ json: [String: Any],
        _ first: String,
        _ second: String,
        default fallback: Double
    ) -> Double {
        if json[first] != nil { return json.double(first, default: fallback) }
        return json.double(second, default: fallback)
    }

    private static func edges(_ value: Any?, fallback: GuideEdgeInsets) -> GuideEdgeInsets {
        if let value = value as? NSNumber {
            let side = spacing(value.doubleValue)
            return GuideEdgeInsets(top: side, right: side, bottom: side, left: side)
        }
        if let value = value as? String, let number = Double(value) {
            let side = spacing(number)
            return GuideEdgeInsets(top: side, right: side, bottom: side, left: side)
        }
        guard let json = value as? [String: Any] else { return fallback }
        return GuideEdgeInsets(
            top: spacing(json.double("top", default: fallback.top)),
            right: spacing(json.double("right", default: fallback.right)),
            bottom: spacing(json.double("bottom", default: fallback.bottom)),
            left: spacing(json.double("left", default: fallback.left))
        )
    }

    private static func spacing(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 64) : 0
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
