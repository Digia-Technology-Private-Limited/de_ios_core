import Foundation
import Combine

/// Whether the floating "Digia" debug bubble (`RecordingBadgeView`) is shown at all —
/// independent of `ComponentRegistryService.isEnabled` (recording mode). The bubble is a
/// general debug-tools launcher (more controls beyond recording will live behind it
/// eventually), so its visibility is its own persisted setting rather than being tied
/// one-to-one to any single feature.
///
/// Turning recording mode on flips this to `true` automatically (see
/// `ComponentRegistryService.setEnabled`) so a developer doesn't have to separately
/// remember to show the bubble — but the reverse doesn't hold: hiding the bubble doesn't
/// stop recording, and turning recording off doesn't hide the bubble.
@MainActor
final class DigiaDebugOverlayController: ObservableObject {
    private static let keyVisible = "digia_debug_overlay_bubble_visible"

    private let defaults: UserDefaults

    @Published private(set) var isVisible: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isVisible = defaults.bool(forKey: Self.keyVisible)
    }

    /// Flips the persisted bubble-visibility toggle. Called from
    /// `DigiaDebugSettingsView`, and internally from `ComponentRegistryService.setEnabled`
    /// when recording turns on.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        defaults.set(visible, forKey: Self.keyVisible)
    }
}
