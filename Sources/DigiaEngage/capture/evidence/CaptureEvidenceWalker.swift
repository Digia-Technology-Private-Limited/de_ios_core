// Module: capture/evidence
//
// The pure walk. No UIKit, no clock, no network, no logging — a tree in, an
// allowlisted node array and an honest `integrity` object out.
//
// Every derivation below is stated by
// `testkit/fixtures/anchorless/cv1-synthetic-screen.json` under `conventions`,
// because §2.6 bounds these numbers without saying how they are produced and four
// stacks must produce one answer:
//
//   nodeId          root is "0"; a child appends ".<childIndex>"
//   paintOrder      preorderIndex / (nodeCount - 1)
//   depth           the root is depth 1
//   effectiveAlpha  the product of ownAlpha from the root down, inclusive
//   inheritedShown  the logical AND of shown from the root down, inclusive
//   clipContainerId the nearest ancestor with clipsChildren
//   clipBoundsPx    the intersection of every such ancestor's rootBoundsPx
//   visibleBoundsPx rootBoundsPx ∩ clipBoundsPx ∩ window; nil when empty
//   visibilityState fullyClipped, else offscreen, else unclipped, else partial
//   visibleFraction visible area / rootBoundsPx area
//   scrollParentId  the nearest ancestor with a scroll block; never itself
//
// I3: the caps are enforced here, on both axes, and `integrity` reports what
// actually happened. §2.7 — `truncated: false` with a limit hit is a rejection,
// not a silent success — so `truncated` and `truncationReason` are written from
// the same fact and cannot disagree.

internal struct CaptureWalkResult: Equatable, Sendable {
    internal let nodes: [CaptureStructuralNode]
    internal let integrity: CaptureIntegrityFacts
}

@MainActor
internal enum CaptureEvidenceWalker {

    internal static func walk(
        root: CaptureNodeSource,
        windowBoundsPx: CaptureEdgeRect,
        maxNodeCount: Int = CaptureLimits.maxNodeCount,
        maxDepth: Int = CaptureLimits.maxDepth
    ) -> CaptureWalkResult {
        var walkState = WalkState(
            windowBoundsPx: windowBoundsPx,
            maxNodeCount: maxNodeCount,
            maxDepth: maxDepth
        )

        if !root.isDigiaOwned {
            visit(
                root,
                nodeId: "0",
                parentId: nil,
                childIndex: 0,
                depth: 1,
                inheritedShown: true,
                inheritedAlpha: 1,
                clipContainerId: nil,
                clipBoundsPx: nil,
                scrollParentId: nil,
                into: &walkState
            )
        }

        // paintOrder is normalized over the emitted count, which is knowable only
        // once the walk has finished.
        let count = walkState.emitted.count
        let divisor = Double(max(1, count - 1))
        let nodes = walkState.emitted.enumerated().map { position, draft in
            draft.finished(paintOrder: count <= 1 ? 0 : Double(position) / divisor)
        }

        return CaptureWalkResult(
            nodes: nodes,
            integrity: CaptureIntegrityFacts(
                nodeCount: count,
                maxDepth: walkState.deepestEmitted,
                truncated: walkState.truncationReason != nil,
                truncationReason: walkState.truncationReason
            )
        )
    }

    // MARK: - Walk

    private struct WalkState {
        let windowBoundsPx: CaptureEdgeRect
        let maxNodeCount: Int
        let maxDepth: Int
        var emitted: [NodeDraft] = []
        var deepestEmitted = 0
        /// First reason wins. §2.7 states no precedence when more than one limit is
        /// hit, and the CV-1 truncation fixtures deliberately never create that
        /// case, so this package does not decide one either — it reports the limit
        /// that actually stopped the walk first.
        var truncationReason: CaptureTruncationReason?

        mutating func note(_ reason: CaptureTruncationReason) {
            if truncationReason == nil { truncationReason = reason }
        }
    }

    private static func visit(
        _ node: CaptureNodeSource,
        nodeId: String,
        parentId: String?,
        childIndex: Int,
        depth: Int,
        inheritedShown: Bool,
        inheritedAlpha: Double,
        clipContainerId: String?,
        clipBoundsPx: CaptureEdgeRect?,
        scrollParentId: String?,
        into walkState: inout WalkState
    ) {
        guard walkState.truncationReason != .nodeLimit else { return }

        guard depth <= walkState.maxDepth else {
            walkState.note(.depthLimit)
            return
        }
        guard walkState.emitted.count < walkState.maxNodeCount else {
            walkState.note(.nodeLimit)
            return
        }

        let localBoundsPx = CaptureEdgeRect(
            left: 0,
            top: 0,
            right: node.sizePx.width,
            bottom: node.sizePx.height
        )
        let rootBoundsPx = mapToRoot(localBoundsPx, through: node.transformToRoot)

        let clipped = clipBoundsPx.map { rootBoundsPx.intersection($0) } ?? rootBoundsPx
        let visible = clipped.intersection(walkState.windowBoundsPx)
        let rootArea = rootBoundsPx.area
        let visibleFraction = rootArea == 0 ? 0 : Double(visible.area) / Double(rootArea)

        let visibilityState: CaptureVisibilityState
        if clipBoundsPx != nil && clipped.isEmpty {
            visibilityState = .fullyClipped
        } else if visible.isEmpty {
            visibilityState = .offscreen
        } else if visible == rootBoundsPx {
            visibilityState = .unclipped
        } else {
            visibilityState = .partiallyClipped
        }

        let shown = inheritedShown && node.shown
        let alpha = inheritedAlpha * node.ownAlpha

        walkState.emitted.append(NodeDraft(
            nodeId: nodeId,
            parentId: parentId,
            childIndex: childIndex,
            localBoundsPx: localBoundsPx,
            transformToRoot: node.transformToRoot,
            rootBoundsPx: rootBoundsPx,
            visibleBoundsPx: visible.isEmpty ? nil : visible,
            clipContainerId: clipContainerId,
            clipBoundsPx: clipBoundsPx,
            inheritedShown: shown,
            effectiveAlpha: alpha,
            visibleFraction: visibleFraction,
            visibilityState: visibilityState,
            scrollAxes: node.scroll?.axes ?? [],
            viewportBoundsPx: node.scroll == nil ? nil : rootBoundsPx,
            scrollOffsetPx: node.scroll?.offsetPx,
            contentExtentPx: node.scroll?.contentExtentPx,
            scrollParentId: scrollParentId,
            virtualized: node.virtualized,
            state: node.state
        ))
        walkState.deepestEmitted = max(walkState.deepestEmitted, depth)

        // A clipping node clips its children, not itself.
        let childClipContainerId = node.clipsChildren ? nodeId : clipContainerId
        let childClipBoundsPx: CaptureEdgeRect?
        if node.clipsChildren {
            childClipBoundsPx = clipBoundsPx.map { rootBoundsPx.intersection($0) } ?? rootBoundsPx
        } else {
            childClipBoundsPx = clipBoundsPx
        }
        // A scroll container does not name itself.
        let childScrollParentId = node.scroll == nil ? scrollParentId : nodeId

        var nextChildIndex = 0
        for child in node.childNodes {
            // T-3: a Digia-owned view and its whole subtree never enter the walk,
            // and never consume a child index either.
            guard !child.isDigiaOwned else { continue }
            visit(
                child,
                nodeId: "\(nodeId).\(nextChildIndex)",
                parentId: nodeId,
                childIndex: nextChildIndex,
                depth: depth + 1,
                inheritedShown: shown,
                inheritedAlpha: alpha,
                clipContainerId: childClipContainerId,
                clipBoundsPx: childClipBoundsPx,
                scrollParentId: childScrollParentId,
                into: &walkState
            )
            nextChildIndex += 1
            if walkState.truncationReason == .nodeLimit { return }
        }
    }

    /// `(x, y)` maps to `(a * x + c * y + tx, b * x + d * y + ty)`. The four corners
    /// are mapped and the axis-aligned hull is taken, so a rotation or a flip
    /// produces a rectangle rather than a negative one.
    internal static func mapToRoot(
        _ rect: CaptureEdgeRect,
        through transform: CaptureAffine
    ) -> CaptureEdgeRect {
        let corners: [(Double, Double)] = [
            (Double(rect.left), Double(rect.top)),
            (Double(rect.right), Double(rect.top)),
            (Double(rect.left), Double(rect.bottom)),
            (Double(rect.right), Double(rect.bottom)),
        ]
        let mapped = corners.map { corner -> (Double, Double) in
            (
                transform.a * corner.0 + transform.c * corner.1 + transform.tx,
                transform.b * corner.0 + transform.d * corner.1 + transform.ty
            )
        }
        let xs = mapped.map(\.0)
        let ys = mapped.map(\.1)
        return CaptureEdgeRect(
            left: rounded(xs.min() ?? 0),
            top: rounded(ys.min() ?? 0),
            right: rounded(xs.max() ?? 0),
            bottom: rounded(ys.max() ?? 0)
        )
    }

    private static func rounded(_ edge: Double) -> Int {
        guard edge.isFinite else { return 0 }
        return Int(edge.rounded())
    }

    /// Everything about a node except `paintOrder`, which needs the final count.
    private struct NodeDraft {
        let nodeId: String
        let parentId: String?
        let childIndex: Int
        let localBoundsPx: CaptureEdgeRect
        let transformToRoot: CaptureAffine
        let rootBoundsPx: CaptureEdgeRect
        let visibleBoundsPx: CaptureEdgeRect?
        let clipContainerId: String?
        let clipBoundsPx: CaptureEdgeRect?
        let inheritedShown: Bool
        let effectiveAlpha: Double
        let visibleFraction: Double
        let visibilityState: CaptureVisibilityState
        let scrollAxes: [CaptureScrollAxis]
        let viewportBoundsPx: CaptureEdgeRect?
        let scrollOffsetPx: CapturePoint?
        let contentExtentPx: CaptureSize?
        let scrollParentId: String?
        let virtualized: Bool
        let state: CaptureNodeState

        func finished(paintOrder: Double) -> CaptureStructuralNode {
            CaptureStructuralNode(
                nodeId: nodeId,
                parentId: parentId,
                childIndex: childIndex,
                paintOrder: paintOrder,
                localBoundsPx: localBoundsPx,
                transformToRoot: transformToRoot,
                rootBoundsPx: rootBoundsPx,
                visibleBoundsPx: visibleBoundsPx,
                clipContainerId: clipContainerId,
                clipBoundsPx: clipBoundsPx,
                inheritedShown: inheritedShown,
                effectiveAlpha: effectiveAlpha,
                visibleFraction: visibleFraction,
                visibilityState: visibilityState,
                // Uninhabited in the locked contracts; see CaptureAllowlistV1.
                containerTraits: [],
                scrollAxes: scrollAxes,
                viewportBoundsPx: viewportBoundsPx,
                scrollOffsetPx: scrollOffsetPx,
                contentExtentPx: contentExtentPx,
                scrollParentId: scrollParentId,
                virtualized: virtualized,
                role: nil,
                supportedActions: [],
                enabled: state.enabled,
                selected: state.selected,
                checked: state.checked,
                expanded: state.expanded,
                focused: state.focused,
                editable: state.editable,
                hasText: state.hasText,
                renderedLineCount: state.renderedLineCount,
                hasAccessibilityLabel: state.hasAccessibilityLabel,
                // §2.6 lists `valid` under Integrity with no stated condition under
                // which a node is invalid, and no locked contract supplies one. A
                // node that reached this point was walked without incident, so it
                // is reported valid; inventing a falsifying condition would be a
                // product decision this package is not entitled to make.
                valid: true
            )
        }
    }
}
