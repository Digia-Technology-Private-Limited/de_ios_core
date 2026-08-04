import Foundation
import SwiftUI

/// How a nudge surface presents over the host app. Mirrors Flutter's
/// `NudgeDisplayType` (`nudge_config.dart`).
enum NudgeDisplayType: String, Equatable, Sendable {
    case bottomSheet
    case dialog

    /// Decoded from the `container.displayType` wire value (default
    /// `bottom_sheet`); only the literal `dialog` selects the dialog frame.
    static func from(_ value: String?) -> NudgeDisplayType {
        value == "dialog" ? .dialog : .bottomSheet
    }

    /// Analytics `display_style` value carried alongside nudge events.
    var displayStyle: String {
        switch self {
        case .bottomSheet: return "bottom_sheet"
        case .dialog: return "dialog"
        }
    }
}

struct NudgeCloseButtonConfig: Equatable {
    let marginTop: CGFloat
    let marginRight: CGFloat
    let backgroundColor: Color
    let iconColor: Color
    let iconSize: CGFloat

    var diameter: CGFloat { iconSize + 10 }

    func scaled(_ factor: CGFloat) -> NudgeCloseButtonConfig {
        NudgeCloseButtonConfig(
            marginTop: marginTop * factor,
            marginRight: marginRight * factor,
            backgroundColor: backgroundColor,
            iconColor: iconColor,
            iconSize: iconSize * factor
        )
    }

    static let defaults = NudgeCloseButtonConfig(
        marginTop: 12,
        marginRight: 12,
        backgroundColor: Color(hex: "#14000000") ?? .clear,
        iconColor: Color(hex: "#66667A") ?? .secondary,
        iconSize: 16
    )

    static func fromJson(_ json: [String: Any]?) -> NudgeCloseButtonConfig {
        let map = json ?? [:]
        let defaults = NudgeCloseButtonConfig.defaults
        return NudgeCloseButtonConfig(
            marginTop: nonNegative(
                map.double("marginTop", default: Double(defaults.marginTop)),
                fallback: defaults.marginTop
            ),
            marginRight: nonNegative(
                map.double("marginRight", default: Double(defaults.marginRight)),
                fallback: defaults.marginRight
            ),
            backgroundColor: Color(hex: map.string("backgroundColor")) ?? defaults.backgroundColor,
            iconColor: Color(hex: map.string("iconColor")) ?? defaults.iconColor,
            iconSize: nonNegative(
                map.double("iconSize", default: Double(defaults.iconSize)),
                fallback: defaults.iconSize
            )
        )
    }

    private static func nonNegative(_ value: Double, fallback: CGFloat) -> CGFloat {
        value.isFinite ? max(0, CGFloat(value)) : fallback
    }
}

/// The presentation chrome for a nudge — everything *around* the content tree.
/// Mirrors Flutter's `NudgeSurface` (`nudge_config.dart`): a pure value object,
/// decoded from the `container` wire object. The content layout (spacing /
/// alignment) lives on the `NudgeColumn`, so this only describes how the modal
/// frame looks and behaves.
struct NudgeSurface: Equatable {
    let displayType: NudgeDisplayType
    /// Surface background; nil inherits white at render time.
    let backgroundColor: Color?
    /// Scrim/barrier colour behind the surface; nil inherits the default
    /// (black at ~30% opacity) at render time.
    let barrierColor: Color?
    let cornerRadius: CGFloat
    /// Uniform inner padding around the content tree, in points.
    let padding: CGFloat
    /// Dismiss when the scrim/barrier outside the surface is tapped.
    let backdropDismissible: Bool
    /// Render an "×" close affordance on the surface.
    let showCloseButton: Bool
    /// Visual configuration for the fixed cross close affordance.
    let closeButton: NudgeCloseButtonConfig
    /// Show the drag-handle pill at the top of the sheet (bottom sheet only).
    let showHandle: Bool
    /// Allow dragging the sheet down to dismiss (bottom sheet only).
    let draggable: Bool
    /// Dialog width as a fraction of the selected safe/full window area, 0…1.
    let widthFraction: CGFloat
    /// Minimum horizontal viewport margin in authored logical pixels.
    let minHorizontalMargin: CGFloat
    /// Keep dialog content inside system safe-area insets (dialog only).
    let useSafeArea: Bool

    var isBottomSheet: Bool { displayType == .bottomSheet }

    func scaled(_ factor: CGFloat) -> NudgeSurface {
        NudgeSurface(
            displayType: displayType,
            backgroundColor: backgroundColor,
            barrierColor: barrierColor,
            cornerRadius: cornerRadius * factor,
            padding: padding * factor,
            backdropDismissible: backdropDismissible,
            showCloseButton: showCloseButton,
            closeButton: closeButton.scaled(factor),
            showHandle: showHandle,
            draggable: draggable,
            widthFraction: widthFraction,
            minHorizontalMargin: minHorizontalMargin,
            useSafeArea: useSafeArea
        )
    }

    /// Decodes from the `container` object. Field names and defaults match
    /// Flutter's `NudgeParser._surface`.
    static func fromJson(_ json: [String: Any]?) -> NudgeSurface {
        let map = json ?? [:]
        let widthPct = map.double("widthPct", default: 86)
        let decodedMargin = map.double("minHorizontalMargin", default: 24)
        return NudgeSurface(
            displayType: NudgeDisplayType.from(map["displayType"] as? String),
            backgroundColor: color(map.string("backgroundColor")),
            barrierColor: color(map.string("barrierColor")),
            cornerRadius: CGFloat(map.double("cornerRadius", default: 18)),
            padding: CGFloat(map.double("padding", default: 20)),
            backdropDismissible: map.bool("backdropDismissible", default: true),
            showCloseButton: map.bool("showCloseButton", default: false),
            closeButton: NudgeCloseButtonConfig.fromJson(map["closeButton"] as? [String: Any]),
            showHandle: map.bool("showHandle", default: true),
            draggable: map.bool("draggable", default: true),
            // Stored as a 0…100 percentage; normalise to a 0…1 fraction.
            widthFraction: CGFloat(min(max(widthPct / 100, 0.3), 1.0)),
            minHorizontalMargin: CGFloat(
                decodedMargin.isFinite ? max(0, decodedMargin) : 24
            ),
            useSafeArea: (map["useSafeArea"] as? NSNumber).map {
                CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
            } ?? false
        )
    }

    private static func color(_ hex: String) -> Color? {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Color(hex: trimmed)
    }
}

/// A fully parsed nudge: the presentation [surface] plus the typed content tree
/// ([layout]) the renderer draws inside it. Mirrors Flutter's `NudgeConfig`.
struct NudgeConfig: Equatable {
    let surface: NudgeSurface
    let layout: NudgeColumn
    let canvas: NudgeCanvas?
    let designWidth: CGFloat
    /// Dashboard-declared variable schemas (`templateConfig.variables`). Carries
    /// name, type, and fallbackValue for each declared variable; resolved against
    /// CEP trigger variables at render time via `buildVariableContext()`.
    let variableSchemas: [VariableSchema]

    /// Decodes a nudge `templateConfig` (`{ container, layout, variables }`).
    /// Returns nil when the content tree is missing — such a campaign has
    /// nothing to show.
    static func fromJson(_ json: [String: Any]) -> NudgeConfig? {
        let rawDesignWidth = CGFloat(json.double("designWidth", default: Double(defaultCanvasDesignWidth)))
        let designWidth = rawDesignWidth.isFinite && rawDesignWidth > 0
            ? rawDesignWidth : defaultCanvasDesignWidth
        let parser = NudgeParser()
        let canvas: NudgeCanvas?
        let layout: NudgeColumn
        if json.string("layoutMode") == "canvas" {
            guard let rawCanvas = json["canvas"] as? [String: Any] else { return nil }
            canvas = parser.parseCanvas(rawCanvas)
            layout = NudgeColumn(
                crossAxisAlignment: .start,
                mainAxisAlignment: .start,
                children: []
            )
        } else {
            guard let parsedLayout = parser.parse(json) else { return nil }
            canvas = nil
            layout = parsedLayout
        }
        return NudgeConfig(
            surface: NudgeSurface.fromJson(json["container"] as? [String: Any]),
            layout: layout,
            canvas: canvas,
            designWidth: designWidth,
            variableSchemas: parseVariableSchemas(json)
        )
    }

    /// Parse dashboard-declared variable schemas from `templateConfig.variables`.
    /// Accepts a list `[{ name, type?, fallbackValue?, sampleValue? }]` (D29: absent
    /// type → "string", absent fallbackValue falls back to sampleValue).
    /// A plain string-map is also accepted for forward compatibility (type → "string").
    static func parseVariableSchemas(_ templateConfig: [String: Any]) -> [VariableSchema] {
        var result: [VariableSchema] = []
        if let list = templateConfig["variables"] as? [[String: Any]] {
            for entry in list {
                guard let name = entry["name"] as? String, !name.isEmpty else { continue }
                let rawType = entry["type"] as? String
                let fallback = stringifyVariable(entry.keys.contains("fallbackValue") ? entry["fallbackValue"] : nil)
                let sample = stringifyVariable(entry["sampleValue"])
                result.append(normalizeVariable(
                    name: name,
                    type: rawType,
                    fallbackValue: fallback,
                    sampleValue: sample
                ))
            }
        } else if let map = templateConfig["variables"] as? [String: Any] {
            for (key, raw) in map {
                if let value = stringifyVariable(raw) {
                    result.append(VariableSchema(name: key, type: "string", fallbackValue: value))
                }
            }
        }
        return result
    }

    private static func stringifyVariable(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        default:
            return nil
        }
    }
}

/// Active nudge state held on the overlay controller and rendered by
/// `NudgeOverlayView`. Carries the resolved `VariableContext` so the renderer
/// can interpolate `{{ placeholder }}` copy and arithmetic expressions.
struct DigiaNudgePresentation: Equatable, Identifiable {
    let config: NudgeConfig
    let payload: CEPTriggerPayload
    let variables: VariableContext?
    var id: String { payload.cepCampaignId }
}
