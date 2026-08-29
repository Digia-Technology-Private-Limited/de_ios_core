import Foundation
import Combine

/// Whether the floating "Digia" debug bubble (`RecordingBadgeView`) is shown at
/// all — independent of `ComponentRegistryService.isEnabled` (recording mode),
/// since the bubble is a general debug-tools launcher, not tied to one feature.
///
/// Turning recording mode on flips this to `true` automatically, but the
/// reverse doesn't hold: hiding the bubble or turning recording off doesn't
/// affect the other.
@MainActor
final class DigiaDebugOverlayController: ObservableObject {
    private static let keyVisible = "digia_debug_overlay_bubble_visible"

    private let defaults: UserDefaults

    @Published private(set) var isVisible: Bool

    /// The bubble's current on-screen frame, kept in sync by `RecordingBadgeView`.
    /// Exposed via `Digia.debugBadgeFrame` so a host's hit-testing (see
    /// `DigiaRootOverlayView` in rn/core) can tell a touch on the bubble apart
    /// from empty SwiftUI space — UIKit's `hitTest` can't distinguish the two on
    /// its own, since SwiftUI is backed by a single hosting `UIView`.
    var badgeFrame: CGRect?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // No persisted toggle yet → default visible; `applyConfigDefault` may
        // lower this once `DigiaConfig.showDebugTools` is known at initialize.
        self.isVisible = (defaults.object(forKey: Self.keyVisible) as? Bool) ?? true
    }

    /// Applies `DigiaConfig.showDebugTools` as the default visibility. A
    /// per-device toggle previously persisted via `setVisible` wins over the
    /// config default, so this is a no-op once the user has flipped the toggle.
    func applyConfigDefault(_ visible: Bool) {
        guard defaults.object(forKey: Self.keyVisible) == nil else { return }
        isVisible = visible
    }

    /// Flips the persisted bubble-visibility toggle. Called from
    /// `DigiaDebugSettingsView`, and internally from `ComponentRegistryService.setEnabled`
    /// when recording turns on.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        defaults.set(visible, forKey: Self.keyVisible)
    }
}
