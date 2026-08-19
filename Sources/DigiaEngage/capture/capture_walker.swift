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
        let parentId: String?
        let rect: CaptureEdgeRect
        let visibleRect: CaptureEdgeRect?
        let visible: Bool
        let nodeType: CaptureNodeType
        let scrollAxis: CaptureScrollAxis?
        let selected: Bool
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

    private var hasGesture: Bool {
        !(view is UIWindow) && !(view.gestureRecognizers?.isEmpty ?? true)
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
