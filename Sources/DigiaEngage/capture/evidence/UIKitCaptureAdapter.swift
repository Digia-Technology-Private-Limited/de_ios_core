// Module: capture/evidence
//
// The **only** file in the capture tree that touches UIKit, and the only one that
// reads anything from a host view at all.
//
// It exists so the boundary is one file long. Everything on the far side of
// `CaptureNodeSource` is a `Bool`, an `Int`, or a rectangle; nothing that crosses
// it can carry a character a user typed. Concentrating the reads here is what makes
// the I2 claim checkable by reading a single file rather than a subsystem.
//
// The three reads that matter, and what they deliberately do **not** do:
//
//   hasText                 asks `UITextInput.hasText` — a `Bool` the responder
//                           already publishes. It never reads the characters, so
//                           `isSecureTextEntry` is not a case to remember to
//                           handle: a secure field and an ordinary field take the
//                           identical path and produce the identical `Bool`. That
//                           is the structural difference from the POC, which read
//                           the string first and had no secure check at all.
//   hasAccessibilityLabel   asks only whether an accessibility description exists.
//   renderedLineCount       is derived from geometry, never from content.
//
// ARCH-2: nothing in `anchorless/*` is named here.

import Foundation
#if canImport(UIKit)
import UIKit

/// A view Digia Engage owns. §5 — Digia-owned overlays are excluded from both the
/// PNG and the node walk.
///
/// Declared as a marker protocol rather than by naming overlay classes, so the
/// capture tree never imports a presentation-host type (ARCH-3). The conformances
/// live outside both trees.
internal protocol DigiaCaptureExcludedView: AnyObject {}

/// Wraps one `UIView` as a `CaptureNodeSource`.
@MainActor
internal struct UIKitCaptureNode: CaptureNodeSource {
    private let view: UIView
    private let rootView: UIView
    private let density: CGFloat
    private let excluded: Set<ObjectIdentifier>

    internal init(
        view: UIView,
        rootView: UIView,
        density: CGFloat,
        excluded: Set<ObjectIdentifier> = []
    ) {
        self.view = view
        self.rootView = rootView
        self.density = density
        self.excluded = excluded
    }

    internal var childNodes: [CaptureNodeSource] {
        view.subviews.map {
            UIKitCaptureNode(view: $0, rootView: rootView, density: density, excluded: excluded)
        }
    }

    internal var nodeType: CaptureNodeType {
        if view is UIScrollView { return .container }
        if view is UIControl || (view as? UITextView)?.isEditable == true ||
            !(view.gestureRecognizers?.isEmpty ?? true) {
            return .interactive
        }
        if view is UIImageView { return .image }
        if view is UILabel || view is UITextView { return .text }
        if view is UIScrollView || !view.subviews.isEmpty { return .container }
        return .unknown
    }

    internal var sizePx: CaptureSize {
        CaptureSize(
            width: Int((view.bounds.width * density).rounded()),
            height: Int((view.bounds.height * density).rounded())
        )
    }

    /// Three mapped points determine an affine map exactly. The linear part is
    /// unit-free, so only the translation is scaled into physical pixels.
    internal var transformToRoot: CaptureAffine {
        let origin = view.convert(CGPoint(x: 0, y: 0), to: rootView)
        let alongX = view.convert(CGPoint(x: 1, y: 0), to: rootView)
        let alongY = view.convert(CGPoint(x: 0, y: 1), to: rootView)
        return CaptureAffine(
            a: Double(alongX.x - origin.x),
            b: Double(alongX.y - origin.y),
            c: Double(alongY.x - origin.x),
            d: Double(alongY.y - origin.y),
            tx: Double(origin.x * density),
            ty: Double(origin.y * density)
        )
    }

    internal var shown: Bool { !view.isHidden }

    internal var ownAlpha: Double { Double(view.alpha) }

    internal var clipsChildren: Bool { view.clipsToBounds }

    internal var scroll: CaptureScrollFacts? {
        guard let scrollView = view as? UIScrollView else { return nil }
        var axes: [CaptureScrollAxis] = []
        if scrollView.contentSize.width > scrollView.bounds.width { axes.append(.horizontal) }
        if scrollView.contentSize.height > scrollView.bounds.height { axes.append(.vertical) }
        return CaptureScrollFacts(
            axes: axes,
            offsetPx: CapturePoint(
                x: Int((scrollView.contentOffset.x * density).rounded()),
                y: Int((scrollView.contentOffset.y * density).rounded())
            ),
            contentExtentPx: CaptureSize(
                width: Int((scrollView.contentSize.width * density).rounded()),
                height: Int((scrollView.contentSize.height * density).rounded())
            )
        )
    }

    internal var virtualized: Bool {
        view is UITableView || view is UICollectionView
    }

    internal var isDigiaOwned: Bool {
        view is DigiaCaptureExcludedView || excluded.contains(ObjectIdentifier(view))
    }

    internal var state: CaptureNodeState {
        CaptureNodeState(
            enabled: (view as? UIControl)?.isEnabled ?? true,
            selected: (view as? UIControl)?.isSelected ?? false,
            checked: Self.checked(view),
            // §2.6 gives `expanded` no UIKit-side definition and no locked contract
            // supplies one, so it is reported absent rather than guessed.
            expanded: nil,
            focused: view.isFirstResponder,
            editable: Self.editable(view),
            hasText: Self.hasCharacters(view),
            renderedLineCount: Self.renderedLineCount(view),
            hasAccessibilityLabel: Self.hasAccessibilityDescription(view)
        )
    }

    // MARK: - The content-adjacent reads, all in one place

    /// Whether the responder holds any characters — never which.
    ///
    /// `UITextInput.hasText` is a published `Bool`. A field with
    /// `isSecureTextEntry` set takes exactly this path and produces exactly this
    /// answer, so there is no secure-field branch to forget. Guarded by T-1.
    private static func hasCharacters(_ view: UIView) -> Bool {
        if let input = view as? UITextInput { return input.hasText }
        if let label = view as? UILabel { return (label.attributedText?.length ?? 0) > 0 }
        if let button = view as? UIButton {
            return (button.titleLabel?.attributedText?.length ?? 0) > 0
        }
        return false
    }

    /// Whether an accessibility description exists — never what it says.
    ///
    /// UIKit derives `accessibilityAttributedLabel` from the plain description, so
    /// presence can be established without the plain accessor ever being named.
    private static func hasAccessibilityDescription(_ view: UIView) -> Bool {
        (view.accessibilityAttributedLabel?.length ?? 0) > 0
    }

    /// Geometry, not content: how many lines of the current font fit in the laid-out
    /// height. Coarse by contract (§2.6).
    private static func renderedLineCount(_ view: UIView) -> Int {
        guard hasCharacters(view) else { return 0 }
        let lineHeight: CGFloat
        if let label = view as? UILabel {
            lineHeight = label.font?.lineHeight ?? 0
        } else if let editor = view as? UITextView {
            lineHeight = editor.font?.lineHeight ?? 0
        } else {
            return 1
        }
        guard lineHeight > 0 else { return 1 }
        return max(1, Int((view.bounds.height / lineHeight).rounded(.down)))
    }

    private static func editable(_ view: UIView) -> Bool {
        if let editor = view as? UITextView { return editor.isEditable }
        return view is UITextField
    }

    private static func checked(_ view: UIView) -> Bool? {
        if let toggle = view as? UISwitch { return toggle.isOn }
        return nil
    }
}

/// The §2.3 capture frame, §2.4 app facts, and §2.5 runtime facts, read from the
/// host once per capture.
@MainActor
internal enum UIKitCaptureFacts {

    internal static func sourceFrame(window: UIWindow) -> CaptureSourceFrame? {
        let density = window.screen.scale
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // §2.3 — the Beta is portrait phones only, and `CaptureOrientation` has no
        // landscape member, so a landscape window produces no frame at all.
        guard bounds.height >= bounds.width else { return nil }
        guard window.effectiveUserInterfaceLayoutDirection == .leftToRight else { return nil }

        let insets = window.safeAreaInsets
        let windowBoundsPx = CaptureEdgeRect(
            left: 0,
            top: 0,
            right: Int((bounds.width * density).rounded()),
            bottom: Int((bounds.height * density).rounded())
        )
        let insetsPx = CaptureInsets(
            left: Int((insets.left * density).rounded()),
            top: Int((insets.top * density).rounded()),
            right: Int((insets.right * density).rounded()),
            bottom: Int((insets.bottom * density).rounded())
        )
        let appContentBoundsPx = CaptureEdgeRect(
            left: windowBoundsPx.left + insetsPx.left,
            top: windowBoundsPx.top + insetsPx.top,
            right: windowBoundsPx.right - insetsPx.right,
            bottom: windowBoundsPx.bottom - insetsPx.bottom
        )
        guard !appContentBoundsPx.isEmpty else { return nil }

        return CaptureSourceFrame(
            density: Double(density),
            windowBoundsPx: windowBoundsPx,
            appContentBoundsPx: appContentBoundsPx,
            orientation: .portrait,
            layoutDirection: .ltr
        )
    }

}
#endif
