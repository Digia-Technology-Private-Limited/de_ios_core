import SwiftUI

// Ambient variable context for the active campaign session.
// Provided at the overlay level; consumed via @Environment by any view that renders text.

struct DigiaVariablesKey: EnvironmentKey {
    static let defaultValue: VariableContext? = nil
}

extension EnvironmentValues {
    var digiaVariables: VariableContext? {
        get { self[DigiaVariablesKey.self] }
        set { self[DigiaVariablesKey.self] = newValue }
    }
}

struct DigiaCampaignKeyKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The campaign a rendered view belongs to, for health reports from media callbacks.
    var digiaCampaignKey: String? {
        get { self[DigiaCampaignKeyKey.self] }
        set { self[DigiaCampaignKeyKey.self] = newValue }
    }
}

struct DigiaCanvasChildIdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The id of the canvas child being rendered, so a widget that needs a stable identity for its
    /// node (a video's pool key, OD-15) can build one. Android's `LocalCanvasChildId`.
    var digiaCanvasChildId: String? {
        get { self[DigiaCanvasChildIdKey.self] }
        set { self[DigiaCanvasChildIdKey.self] = newValue }
    }
}
