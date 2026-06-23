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
    /// Show the drag-handle pill at the top of the sheet (bottom sheet only).
    let showHandle: Bool
    /// Allow dragging the sheet down to dismiss (bottom sheet only).
    let draggable: Bool
    /// Dialog width as a fraction of the screen width, 0…1 (dialog only).
    let widthFraction: CGFloat

    var isBottomSheet: Bool { displayType == .bottomSheet }

    /// Decodes from the `container` object. Field names and defaults match
    /// Flutter's `NudgeParser._surface`.
    static func fromJson(_ json: [String: Any]?) -> NudgeSurface {
        let map = json ?? [:]
        let widthPct = map.double("widthPct", default: 86)
        return NudgeSurface(
            displayType: NudgeDisplayType.from(map["displayType"] as? String),
            backgroundColor: color(map.string("backgroundColor")),
            barrierColor: color(map.string("barrierColor")),
            cornerRadius: CGFloat(map.double("cornerRadius", default: 18)),
            padding: CGFloat(map.double("padding", default: 20)),
            backdropDismissible: map.bool("backdropDismissible", default: true),
            showCloseButton: map.bool("showCloseButton", default: false),
            showHandle: map.bool("showHandle", default: true),
            draggable: map.bool("draggable", default: true),
            // Stored as a 0…100 percentage; normalise to a 0…1 fraction.
            widthFraction: CGFloat(min(max(widthPct / 100, 0.3), 1.0))
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
    /// Dashboard-declared variable schemas (`templateConfig.variables`). Carries
    /// name, type, and fallbackValue for each declared variable; resolved against
    /// CEP trigger variables at render time via `buildVariableContext()`.
    let variableSchemas: [VariableSchema]

    /// Decodes a nudge `templateConfig` (`{ container, layout, variables }`).
    /// Returns nil when the content tree is missing — such a campaign has
    /// nothing to show.
    static func fromJson(_ json: [String: Any]) -> NudgeConfig? {
        guard let layout = NudgeParser().parse(json) else { return nil }
        return NudgeConfig(
            surface: NudgeSurface.fromJson(json["container"] as? [String: Any]),
            layout: layout,
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
