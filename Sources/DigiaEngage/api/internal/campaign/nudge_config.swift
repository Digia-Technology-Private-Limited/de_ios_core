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
    /// Dashboard-declared variable defaults (`templateConfig.variables`). The
    /// CEP trigger payload's variables are layered on top of these at render
    /// time (CEP wins). Mirrors Flutter's `CampaignConfig.defaultVariables`.
    let defaultVariables: [String: String]

    /// Decodes a nudge `templateConfig` (`{ container, layout, variables }`).
    /// Returns nil when the content tree is missing — such a campaign has
    /// nothing to show.
    static func fromJson(_ json: [String: Any]) -> NudgeConfig? {
        guard let layout = NudgeParser().parse(json) else { return nil }
        return NudgeConfig(
            surface: NudgeSurface.fromJson(json["container"] as? [String: Any]),
            layout: layout,
            defaultVariables: declaredVariables(json)
        )
    }

    /// The dashboard-declared variable defaults on a `templateConfig`, as a
    /// `name -> value` map (empty when absent). Mirrors Flutter's
    /// `_declaredVariables`: the backend sends `variables` as a list of
    /// `{ name, fallbackValue?, sampleValue? }` entries, folded into a map keyed
    /// by `name` (value = `fallbackValue` ?? `sampleValue`). A plain map is also
    /// accepted for forward compatibility. Values are stringified for
    /// `{{ }}` interpolation.
    private static func declaredVariables(_ templateConfig: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        if let list = templateConfig["variables"] as? [[String: Any]] {
            for entry in list {
                guard let name = entry["name"] as? String, !name.isEmpty else { continue }
                let raw = entry.keys.contains("fallbackValue") ? entry["fallbackValue"] : entry["sampleValue"]
                if let value = stringifyVariable(raw) { result[name] = value }
            }
        } else if let map = templateConfig["variables"] as? [String: Any] {
            for (key, raw) in map {
                if let value = stringifyVariable(raw) { result[key] = value }
            }
        }
        return result
    }

    private static func stringifyVariable(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            // Distinguish booleans from numeric NSNumbers so a declared
            // `flag: true` reads as "true" rather than "1".
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
/// `NudgeOverlayView`. Carries the trigger `variables` so the renderer can
/// interpolate `{{ placeholder }}` copy (mirrors Flutter's `VariableScope`
/// threaded into `presentNudge`).
struct DigiaNudgePresentation: Equatable, Identifiable {
    let config: NudgeConfig
    let payload: CEPTriggerPayload
    let variables: [String: String]?
    var id: String { payload.cepCampaignId }
}
