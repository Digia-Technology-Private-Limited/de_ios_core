import Foundation
import UIKit

@MainActor
internal protocol CaptureNodeSource {
    var childNodes: [CaptureNodeSource] { get }
    var rootBounds: CaptureEdgeRect { get }
    var shown: Bool { get }
    var alpha: Double { get }
    var nodeType: CaptureNodeType { get }
    var scrollAxis: CaptureScrollAxis? { get }
}

internal enum CaptureWalkRefusal: Equatable, Sendable {
    case cancelled
    case timeBudgetExceeded
    case noCapturableNodes
}

internal enum CaptureWalkResult: Equatable, Sendable {
    case succeeded(nodes: [CaptureStructuralNode], traversal: CaptureTraversalFacts)
    case refused(CaptureWalkRefusal, traversal: CaptureTraversalFacts)
}

@MainActor
internal enum CaptureEvidenceWalker {
    private static let maximumElapsedTime: TimeInterval = 0.5
    private static let nodesPerYield = 128

    internal static func walk(
        root: CaptureNodeSource,
        windowBoundsPx: CaptureEdgeRect,
        profile: CaptureProfile
    ) async -> CaptureWalkResult {
        let startedAt = Date()
        var visited: [VisitedNode] = []
        var pending = [PendingNode(node: root, id: "0", parentId: nil)]
        var processed = 0

        while let current = pending.popLast() {
            if processed > 0, processed.isMultiple(of: nodesPerYield) { await Task.yield() }
            if let refusal = refusal(startedAt: startedAt, visited: visited.count) {
                return refusal
            }
            processed += 1
            let rect = current.node.rootBounds
            let visibleRect = rect.intersection(windowBoundsPx)
            let visible = current.node.shown
                && current.node.alpha > 0
                && !rect.isEmpty
                && visibleRect != nil
            let nodeType = current.node.nodeType
            let scrollAxis = current.node.scrollAxis
            visited.append(VisitedNode(
                id: current.id,
                parentId: current.parentId,
                rect: rect,
                visibleRect: visibleRect,
                visible: visible,
                nodeType: nodeType,
                scrollAxis: scrollAxis,
                selected: selected(nodeType, scrollAxis: scrollAxis, profile: profile)
            ))

            let children = current.node.childNodes
            for index in children.indices.reversed() {
                pending.append(PendingNode(
                    node: children[index],
                    id: "\(current.id).\(index)",
                    parentId: current.id
                ))
            }
        }

        visited = collapsingPassThroughDuplicates(visited, profile: profile)

        var included = Set(visited.filter(\.selected).map(\.id))
        for (index, node) in visited.enumerated().reversed() {
            if index > 0, index.isMultiple(of: nodesPerYield) { await Task.yield() }
            if let refusal = refusal(startedAt: startedAt, visited: visited.count) {
                return refusal
            }
            if included.contains(node.id), let parentId = node.parentId {
                included.insert(parentId)
            }
        }

        var visibleAncestorById: [String: String] = [:]
        var childCounts: [String: Int] = [:]
        var nodes: [CaptureStructuralNode] = []
        for (index, node) in visited.enumerated() where included.contains(node.id) {
            if index > 0, index.isMultiple(of: nodesPerYield) { await Task.yield() }
            if let refusal = refusal(
                startedAt: startedAt,
                visited: visited.count,
                captured: nodes.count
            ) {
                return refusal
            }
            let parentId = node.parentId.flatMap { visibleAncestorById[$0] }
            if node.visible {
                visibleAncestorById[node.id] = node.id
            } else if let parentId {
                visibleAncestorById[node.id] = parentId
            }
            guard node.visible, let visibleRect = node.visibleRect else { continue }

            let parentKey = parentId ?? ""
            let childIndex = childCounts[parentKey, default: 0]
            childCounts[parentKey] = childIndex + 1
            nodes.append(CaptureStructuralNode(
                nodeId: node.id,
                parentId: parentId,
                childIndex: childIndex,
                rootBoundsPx: node.rect,
                fullyVisible: visibleRect == node.rect,
                nodeType: node.nodeType,
                scrollAxis: node.scrollAxis
            ))
        }

        let traversal = facts(startedAt: startedAt, visited: visited.count, captured: nodes.count)
        return nodes.isEmpty
            ? .refused(.noCapturableNodes, traversal: traversal)
            : .succeeded(nodes: nodes, traversal: traversal)
    }

    /// Merges a node into its parent when both occupy the same rectangle (within a point), so one
    /// element is not reported twice: a `UISwitch` and the view or accessibility element that
    /// shares its rect, or a chain of wrappers around one view. The survivor is the parent, which
    /// keeps its id and takes the more meaningful type; the merged node's children move to it.
    /// Two meaningful elements of different kinds (a button and a label that happen to share a
    /// size) are distinct and stay apart.
    private static func collapsingPassThroughDuplicates(
        _ visited: [VisitedNode],
        profile: CaptureProfile
    ) -> [VisitedNode] {
        var kept: [VisitedNode] = []
        var indexById: [String: Int] = [:]
        var survivorById: [String: String] = [:]
        for var node in visited {
            if let parentId = node.parentId {
                let resolvedId = survivorById[parentId] ?? parentId
                node.parentId = resolvedId
                if let index = indexById[resolvedId], let merged = kept[index].absorbing(node, profile: profile) {
                    kept[index] = merged
                    survivorById[node.id] = resolvedId
                    continue
                }
            }
            indexById[node.id] = kept.count
            kept.append(node)
        }
        return kept
    }

    private static func selected(
        _ type: CaptureNodeType,
        scrollAxis: CaptureScrollAxis?,
        profile: CaptureProfile
    ) -> Bool {
        if type == .interactive || scrollAxis != nil { return true }
        switch type {
        case .text: return profile.includeText
        case .image: return profile.includeImagesAndMedia
        case .container, .unknown: return profile.includeOtherStructuralNodes
        case .interactive: return true
        }
    }

    private static func refusal(
        startedAt: Date,
        visited: Int,
        captured: Int = 0
    ) -> CaptureWalkResult? {
        let traversal = facts(startedAt: startedAt, visited: visited, captured: captured)
        if Task.isCancelled { return .refused(.cancelled, traversal: traversal) }
        if traversal.elapsedMs >= maximumElapsedTime * 1_000 {
            return .refused(.timeBudgetExceeded, traversal: traversal)
        }
        return nil
    }

    private static func facts(
        startedAt: Date,
        visited: Int,
        captured: Int
    ) -> CaptureTraversalFacts {
        CaptureTraversalFacts(
            elapsedMs: Date().timeIntervalSince(startedAt) * 1_000,
            visitedNodeCount: visited,
            capturedNodeCount: captured
        )
    }

    private struct PendingNode {
        let node: CaptureNodeSource
        let id: String
        let parentId: String?
    }

    private struct VisitedNode {
        let id: String
        var parentId: String?
        let rect: CaptureEdgeRect
        let visibleRect: CaptureEdgeRect?
        let visible: Bool
        var nodeType: CaptureNodeType
        var scrollAxis: CaptureScrollAxis?
        var selected: Bool

        /// What this node becomes by taking in `child`, or nil when they are different elements
        /// (or not in the same place).
        @MainActor
        func absorbing(_ child: VisitedNode, profile: CaptureProfile) -> VisitedNode? {
            guard visible, child.visible, rect.isSame(as: child.rect, within: 1) else { return nil }
            let own = rank, other = child.rank
            if own >= Self.meaningfulRank && other >= Self.meaningfulRank && own != other { return nil }
            if (scrollAxis != nil && other >= Self.meaningfulRank) ||
                (child.scrollAxis != nil && own >= Self.meaningfulRank) { return nil }
            var merged = self
            if other > own { merged.nodeType = child.nodeType }
            merged.scrollAxis = scrollAxis ?? child.scrollAxis
            merged.selected = CaptureEvidenceWalker.selected(
                merged.nodeType, scrollAxis: merged.scrollAxis, profile: profile
            )
            return merged
        }

        private static let meaningfulRank = 3

        /// interactive > text > image > scroll container > container > unknown.
        private var rank: Int {
            switch nodeType {
            case .interactive: return 5
            case .text: return 4
            case .image: return 3
            case .container: return scrollAxis == nil ? 1 : 2
            case .unknown: return 0
            }
        }
    }
}

@MainActor
internal struct UIKitCaptureNode: CaptureNodeSource {
    private let view: UIView
    private let rootView: UIView

    internal init(view: UIView, rootView: UIView) {
        self.view = view
        self.rootView = rootView
    }

    internal var childNodes: [CaptureNodeSource] {
        let subviewNodes: [CaptureNodeSource] = view.subviews.map {
            UIKitCaptureNode(view: $0, rootView: rootView)
        }
        // SwiftUI draws a hosting view's content without one UIView per element, so its
        // subviews say almost nothing. Its accessibility tree does, so it is walked too.
        // Only hosting views: a UIKit or React Native container's accessibility elements
        // mirror its subviews and would be counted twice.
        guard AccessibilityCaptureNode.exposesContentThroughAccessibility(view) else {
            return subviewNodes
        }
        let elements = AccessibilityCaptureNode.children(
            of: view,
            rootView: rootView,
            hostShown: shown,
            hostAlpha: alpha,
            depth: 0
        )
        return subviewNodes + elements
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
            isAccessibilityIntentUnit { return .interactive }
        let className = NSStringFromClass(type(of: view))
        if view is UIImageView || className.hasSuffix("RCTImageView") { return .image }
        if view is UILabel || view is UITextView || className.hasSuffix("RCTTextView") ||
            className.hasSuffix("RCTParagraphComponentView") { return .text }
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

    // Not a control: a hosting view, which carries recognizers of its own for everything SwiftUI
    // draws inside it (the content's controls are its accessibility elements), and a view whose only
    // recognizers are UIKit's own plumbing (`_UIParallaxTransitionPanGestureRecognizer` on a
    // navigation controller's container, `_UISecondaryClickDriverGestureRecognizer` on a bar).
    private var hasGesture: Bool {
        guard !(view is UIWindow), !AccessibilityCaptureNode.exposesContentThroughAccessibility(view) else {
            return false
        }
        return view.gestureRecognizers?.contains {
            !NSStringFromClass(type(of: $0)).hasPrefix("_")
        } ?? false
    }

    private var isAccessibilityIntentUnit: Bool {
        let name = NSStringFromClass(type(of: view))
        guard (name == "RCTView" || name.hasSuffix("RCTViewComponentView")) &&
            view.isAccessibilityElement else { return false }
        if view.accessibilityLabel?.isEmpty == false ||
            (view.accessibilityAttributedLabel?.length ?? 0) > 0 { return true }
        let traits: UIAccessibilityTraits = [.button, .link, .adjustable, .searchField, .keyboardKey]
        return !view.accessibilityTraits.intersection(traits).isEmpty
    }
}

/// A view whose content is reached through its accessibility tree rather than its
/// subviews. SwiftUI hosting views qualify by class; tests adopt it on a plain UIView.
@MainActor
internal protocol CaptureAccessibilityHost: UIView {}

/// One element of a SwiftUI hosting view's accessibility tree, as a capture node.
/// Public UIAccessibility APIs only: `accessibilityElements` /
/// `accessibilityElementCount()` / `accessibilityElement(at:)` for children,
/// `accessibilityFrame` (screen coordinates) for bounds, traits for the node type.
@MainActor
internal struct AccessibilityCaptureNode: CaptureNodeSource {
    /// Guards against cyclic or pathological accessibility trees; the walker's own
    /// time budget still applies on top.
    private static let maximumDepth = 24
    private static let maximumChildren = 512

    private let element: NSObject
    private let rootView: UIView
    private let hostShown: Bool
    private let hostAlpha: Double
    private let depth: Int

    internal static func exposesContentThroughAccessibility(_ view: UIView) -> Bool {
        if view is CaptureAccessibilityHost { return true }
        // e.g. "_TtGC7SwiftUI14_UIHostingView…" or "SwiftUI.UIHostingView<…>". A SwiftUI ScrollView is
        // a "SwiftUI.HostingScrollView" inside it (not its "HostingScrollView.PlatformContainer"
        // parts), which would keep the accessibility elements of its rows.
        let name = NSStringFromClass(type(of: view))
        return name.contains("HostingView") || name.hasSuffix("HostingScrollView")
    }

    internal static func children(
        of container: NSObject,
        rootView: UIView,
        hostShown: Bool,
        hostAlpha: Double,
        depth: Int
    ) -> [CaptureNodeSource] {
        guard depth < maximumDepth else { return [] }
        return accessibilityChildren(of: container)
            // A child that is itself a UIView is already walked as a subview.
            .filter { !($0 is UIView) }
            .prefix(maximumChildren)
            .map {
                AccessibilityCaptureNode(
                    element: $0,
                    rootView: rootView,
                    hostShown: hostShown,
                    hostAlpha: hostAlpha,
                    depth: depth + 1
                )
            }
    }

    private static func rect(of element: NSObject, in rootView: UIView) -> CGRect {
        let screenSpace = rootView.window?.screen.coordinateSpace
            ?? (rootView as? UIWindow)?.screen.coordinateSpace
        let frame = element.accessibilityFrame
        return screenSpace.map { rootView.convert(frame, from: $0) } ?? frame
    }

    private static func accessibilityChildren(of container: NSObject) -> [NSObject] {
        if let elements = container.accessibilityElements, !elements.isEmpty {
            return elements.compactMap { $0 as? NSObject }
        }
        let count = container.accessibilityElementCount()
        guard count != NSNotFound, count > 0 else { return [] }
        return (0..<min(count, maximumChildren)).compactMap {
            container.accessibilityElement(at: $0) as? NSObject
        }
    }

    internal var childNodes: [CaptureNodeSource] {
        Self.children(
            of: element,
            rootView: rootView,
            hostShown: hostShown,
            hostAlpha: hostAlpha,
            depth: depth
        )
    }

    internal var rootBounds: CaptureEdgeRect {
        CaptureEdgeRect(Self.rect(of: element, in: rootView))
    }

    internal var shown: Bool { hostShown && !element.accessibilityElementsHidden }

    internal var alpha: Double { hostAlpha }

    internal var nodeType: CaptureNodeType {
        let traits = element.accessibilityTraits
        let interactive: UIAccessibilityTraits = [
            .button, .link, .adjustable, .searchField, .keyboardKey,
        ]
        if !traits.intersection(interactive).isEmpty { return .interactive }
        if traits.contains(.image) { return .image }
        if traits.contains(.staticText) || traits.contains(.header) { return .text }
        if !Self.accessibilityChildren(of: element).isEmpty { return .container }
        return .unknown
    }

    // A SwiftUI ScrollView is backed by a UIScrollView subview, walked as a subview.
    internal var scrollAxis: CaptureScrollAxis? { nil }
}

extension CaptureEdgeRect {
    fileprivate init(_ rect: CGRect) {
        self.init(
            left: Int(rect.minX.rounded()),
            top: Int(rect.minY.rounded()),
            right: Int(rect.maxX.rounded()),
            bottom: Int(rect.maxY.rounded())
        )
    }
}

@MainActor
internal enum UIKitCaptureFacts {
    internal static func sourceFrame(window: UIWindow) -> CaptureSourceFrame? {
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > bounds.width,
              min(bounds.width, bounds.height) < 600,
              window.effectiveUserInterfaceLayoutDirection == .leftToRight else { return nil }
        let insets = window.safeAreaInsets
        let windowBounds = CaptureEdgeRect(
            left: 0, top: 0, right: Int(bounds.width.rounded()), bottom: Int(bounds.height.rounded())
        )
        let appContent = CaptureEdgeRect(
            left: Int(insets.left.rounded()), top: Int(insets.top.rounded()),
            right: Int((bounds.width - insets.right).rounded()),
            bottom: Int((bounds.height - insets.bottom).rounded())
        )
        guard !appContent.isEmpty else { return nil }
        return CaptureSourceFrame(
            density: Double(window.screen.scale), windowBoundsPx: windowBounds,
            appContentBoundsPx: appContent, orientation: .portrait, layoutDirection: .ltr
        )
    }
}
