import SwiftUI

// Ambient variable map for the active campaign session.
// Provided at the overlay level; consumed via @Environment by any view that renders text.

struct DigiaVariablesKey: EnvironmentKey {
    static let defaultValue: [String: String]? = nil
}

extension EnvironmentValues {
    var digiaVariables: [String: String]? {
        get { self[DigiaVariablesKey.self] }
        set { self[DigiaVariablesKey.self] = newValue }
    }
}
