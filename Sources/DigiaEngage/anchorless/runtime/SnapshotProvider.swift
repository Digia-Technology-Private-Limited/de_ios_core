// Module: anchorless/runtime
//
// Atomic snapshot construction. Native runtime contract §2: one atomic read
// immediately before `resolve`, never re-read per axis, handed to the solver as a
// value. The solver never sees a `UIWindow`.
//
// `SnapshotProvider` is one of the three injected seams that make the Conformance
// Vectors runnable without a device (§10).

import UIKit

/// The seam the runtime reads live frames through.
///
/// `@MainActor` because every implementation that is not a test fake reads UIKit
/// geometry, and because the runtime hands its rectangle to a presentation host on
/// the main actor anyway.
@MainActor
internal protocol SnapshotProvider {
    /// One atomic read of the current window and app-content frames.
    /// Returns `nil` when there is no window to read — the runtime fails closed.
    func currentSnapshot() -> RuntimeGeometrySnapshot?
}

/// The production provider: the guide overlay window in logical points.
@MainActor
internal struct UIWindowSnapshotProvider: SnapshotProvider {
    private let windowSource: @MainActor () -> UIWindow?

    internal init(windowSource: @escaping @MainActor () -> UIWindow? = { UIWindowSnapshotProvider.keyWindow() }) {
        self.windowSource = windowSource
    }

    internal func currentSnapshot() -> RuntimeGeometrySnapshot? {
        guard let window = windowSource(),
              window.effectiveUserInterfaceLayoutDirection == .leftToRight
        else { return nil }

        let bounds = window.bounds
        let windowFrame = FrameRect(
            left: Double(bounds.minX),
            top: Double(bounds.minY),
            right: Double(bounds.maxX),
            bottom: Double(bounds.maxY)
        )

        // `appContent` is `window` minus the safe-area insets, **ignoring the IME**,
        // so a target never moves because a keyboard opened. `safeAreaInsets` does
        // not include the keyboard, so reading it directly is already IME-free;
        // `keyboardLayoutGuide` is deliberately not consulted.
        let insets = window.safeAreaInsets
        let appContent = FrameRect(
            left: Double(bounds.minX + insets.left),
            top: Double(bounds.minY + insets.top),
            right: Double(bounds.maxX - insets.right),
            bottom: Double(bounds.maxY - insets.bottom)
        )

        return RuntimeGeometrySnapshot(
            window: windowFrame,
            appContent: appContent
        )
    }

    internal static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
