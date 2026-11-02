import SwiftUI
import UIKit

// The device's real safe-area insets, read from the key `UIWindow` rather than from SwiftUI.
///
/// A `GeometryReader`'s own `safeAreaInsets` cannot be trusted for a floating window, because what
/// it reports depends on how the *host app* embedded `DigiaHost` — inset inside a safe area, or
/// full-bleed, or somewhere in between — and a full-bleed reader reports zero regardless. A window
/// positioned from that lands under the notch in one app and inset twice over in another.
///
/// The window is the only thing on screen that has to be placed against the physical device rather
/// than against its container, so it asks the device. Extracted verbatim from
/// `api/widgets/floater_overlay_view.swift`; shared with the story floater, which had the
/// same symptom for the same reason.
@MainActor var activeFloaterWindowSafeAreaInsets: EdgeInsets {
    activeFloaterWindowGeometry.safeArea
}

/// Test seam for `activeFloaterWindowGeometry`. The package's test bundle runs without a host app,
/// so there is no window scene to read the device from; snapshot tests pin the device here. Never
/// set in production, where `nil` leaves the lookup below unchanged.
@MainActor var activeFloaterWindowGeometryOverride: (bounds: CGRect, safeArea: EdgeInsets)?

/// The device's screen box and its safe-area insets, taken from the same `UIWindow`.
///
/// Both together, deliberately. Reading the size from SwiftUI and the insets from UIKit is how the
/// story floater ended up inset twice: a `GeometryReader` at the root of a hosting controller
/// reports a size that has *already* had the safe area carved out of it, so subtracting real
/// insets from that height again pushes a window far further in from the top and bottom than the
/// author asked for — barely noticeable on a large window, glaring on a small one, where the gaps
/// are most of what you see.
///
/// Taking both from the window makes the pair consistent by construction, whatever the host app did
/// with `DigiaHost`.
@MainActor var activeFloaterWindowGeometry: (bounds: CGRect, safeArea: EdgeInsets) {
    if let override = activeFloaterWindowGeometryOverride { return override }
    let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
        .flatMap(\.windows)
        .first(where: { $0.safeAreaInsets.top > 0 || $0.safeAreaInsets.bottom > 0 })
        ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    guard let window else { return (.zero, EdgeInsets()) }
    let insets = window.safeAreaInsets
    return (
        window.bounds,
        EdgeInsets(
            top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    )
}
