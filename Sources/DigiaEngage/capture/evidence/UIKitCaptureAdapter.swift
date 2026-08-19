import UIKit

@MainActor
internal struct UIKitCaptureNode: CaptureNodeSource {
    private let view: UIView
    private let rootView: UIView

    internal init(view: UIView, rootView: UIView) {
        self.view = view
        self.rootView = rootView
    }

    internal var childNodes: [CaptureNodeSource] {
        view.subviews.map { UIKitCaptureNode(view: $0, rootView: rootView) }
    }

    internal var rootBounds: CaptureEdgeRect {
        let rect = view.convert(view.bounds, to: rootView)
        return CaptureEdgeRect(
            left: Int(rect.minX.rounded()),
            top: Int(rect.minY.rounded()),
            right: Int(rect.maxX.rounded()),
            bottom: Int(rect.maxY.rounded())
        )
    }

    internal var shown: Bool {
        var current: UIView? = view
        while let node = current {
            if node.isHidden { return false }
            if node === rootView { break }
            current = node.superview
        }
        return true
    }

    internal var alpha: Double {
        var value = 1.0
        var current: UIView? = view
        while let node = current {
            value *= Double(node.alpha)
            if node === rootView { break }
            current = node.superview
        }
        return value
    }

    internal var nodeType: CaptureNodeType {
        if scrollAxis != nil { return .container }
        if view is UIControl || (view as? UITextView)?.isEditable == true || hasGesture ||
            isAccessibilityIntentUnit {
            return .interactive
        }
        let className = NSStringFromClass(type(of: view))
        if view is UIImageView || className.hasSuffix("RCTImageView") { return .image }
        if view is UILabel || view is UITextView
            || className.hasSuffix("RCTTextView")
            || className.hasSuffix("RCTParagraphComponentView") {
            return .text
        }
        if !view.subviews.isEmpty { return .container }
        return .unknown
    }

    internal var scrollAxis: CaptureScrollAxis? {
        guard let scroll = view as? UIScrollView else { return nil }
        let horizontal = scroll.contentSize.width > scroll.bounds.width
        let vertical = scroll.contentSize.height > scroll.bounds.height
        if horizontal && vertical { return .both }
        if horizontal { return .horizontal }
        if vertical { return .vertical }
        return nil
    }

    private var hasGesture: Bool {
        !(view is UIWindow) && !(view.gestureRecognizers?.isEmpty ?? true)
    }

    /// Fabric Pressable/Touchable targets are accessible RCT views; their root
    /// touch handler dispatches presses instead of per-view UIKit gestures.
    private var isAccessibilityIntentUnit: Bool {
        let className = NSStringFromClass(type(of: view))
        let isReactNativeView = className == "RCTView" ||
            className.hasSuffix("RCTViewComponentView")
        guard isReactNativeView, view.isAccessibilityElement else { return false }
        if view.accessibilityLabel?.isEmpty == false { return true }
        if (view.accessibilityAttributedLabel?.length ?? 0) > 0 { return true }

        let actionableTraits: UIAccessibilityTraits = [
            .button,
            .link,
            .adjustable,
            .searchField,
            .keyboardKey,
        ]
        return !view.accessibilityTraits.intersection(actionableTraits).isEmpty
    }
}

@MainActor
internal enum UIKitCaptureFacts {
    internal static func sourceFrame(window: UIWindow) -> CaptureSourceFrame? {
        let bounds = window.bounds
        guard bounds.width > 0,
              bounds.height > bounds.width,
              min(bounds.width, bounds.height) < 600,
              window.effectiveUserInterfaceLayoutDirection == .leftToRight
        else { return nil }

        let insets = window.safeAreaInsets
        let windowBounds = CaptureEdgeRect(
            left: 0,
            top: 0,
            right: Int(bounds.width.rounded()),
            bottom: Int(bounds.height.rounded())
        )
        let appContent = CaptureEdgeRect(
            left: Int(insets.left.rounded()),
            top: Int(insets.top.rounded()),
            right: Int((bounds.width - insets.right).rounded()),
            bottom: Int((bounds.height - insets.bottom).rounded())
        )
        guard !appContent.isEmpty else { return nil }
        return CaptureSourceFrame(
            density: Double(window.screen.scale),
            windowBoundsPx: windowBounds,
            appContentBoundsPx: appContent,
            orientation: .portrait,
            layoutDirection: .ltr
        )
    }
}
