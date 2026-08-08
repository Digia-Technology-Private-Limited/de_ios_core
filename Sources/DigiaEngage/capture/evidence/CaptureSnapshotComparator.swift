// Pure convergence check for hierarchy-before / screenshot / hierarchy-after pairing.

internal enum CaptureSnapshotComparator {
    internal static func matches(
        _ before: CaptureWalkResult,
        _ after: CaptureWalkResult,
        tolerancePx: Int = 1
    ) -> Bool {
        guard !before.integrity.truncated, !after.integrity.truncated,
              before.nodes.count == after.nodes.count
        else { return false }

        return zip(before.nodes, after.nodes).allSatisfy { left, right in
            left.nodeId == right.nodeId &&
                left.parentId == right.parentId &&
                left.childIndex == right.childIndex &&
                left.nodeType == right.nodeType &&
                left.visibilityState == right.visibilityState &&
                left.scrollAxes == right.scrollAxes &&
                nearlyEqual(left.rootBoundsPx, right.rootBoundsPx, tolerance: tolerancePx)
        }
    }

    private static func nearlyEqual(
        _ left: CaptureEdgeRect,
        _ right: CaptureEdgeRect,
        tolerance: Int
    ) -> Bool {
        abs(left.left - right.left) <= tolerance &&
            abs(left.top - right.top) <= tolerance &&
            abs(left.right - right.right) <= tolerance &&
            abs(left.bottom - right.bottom) <= tolerance
    }
}
