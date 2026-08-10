import Foundation

internal enum CaptureEnvelopeSerializer {

    internal static func jsonObject(_ envelope: PageCaptureEnvelopeV1) -> [String: Any] {
        [
            "schemaVersion": PageCaptureEnvelopeV1.captureSchemaVersion,
            "pageKey": envelope.pageKey,
            "platform": envelope.devicePlatform.rawValue,
            "unit": "px",
            "pixelScale": envelope.source.density,
            "orientation": envelope.source.orientation.rawValue,
            "layoutDirection": envelope.source.layoutDirection.rawValue,
            "window": rect(envelope.source.windowBoundsPx),
            "appContent": rect(envelope.source.appContentBoundsPx),
            "nodes": minimalNodes(envelope.nodes),
        ]
    }

    internal static func jsonBytes(_ envelope: PageCaptureEnvelopeV1) -> Data? {
        guard !envelope.integrity.truncated else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: jsonObject(envelope),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func minimalNodes(_ allNodes: [CaptureStructuralNode]) -> [[String: Any]] {
        let included = allNodes.filter(isWireVisible)
        let includedIDs = Set(included.map(\.nodeId))
        let byID = Dictionary(uniqueKeysWithValues: allNodes.map { ($0.nodeId, $0) })
        return included.map { capturedNode in
            var parentID = capturedNode.parentId
            while let candidate = parentID, !includedIDs.contains(candidate) {
                parentID = byID[candidate]?.parentId
            }
            return node(capturedNode, parentID: parentID)
        }
    }

    private static func isWireVisible(_ node: CaptureStructuralNode) -> Bool {
        node.valid && node.inheritedShown && node.effectiveAlpha > 0 && !node.rootBoundsPx.isEmpty &&
            node.visibilityState != .fullyClipped && node.visibilityState != .offscreen
    }

    private static func node(_ node: CaptureStructuralNode, parentID: String?) -> [String: Any] {
        var result: [String: Any] = [
            "id": node.nodeId,
            "parentId": parentID ?? NSNull(),
            "childIndex": node.childIndex,
            "rect": rect(node.rootBoundsPx),
            "viewportVisibility": node.visibilityState == .unclipped
                ? "fullyVisible"
                : "partiallyVisible",
            "nodeType": node.nodeType.rawValue,
        ]
        let axes = Set(node.scrollAxes)
        if axes == Set([CaptureScrollAxis.horizontal]) { result["scrollAxis"] = "horizontal" }
        if axes == Set([CaptureScrollAxis.vertical]) { result["scrollAxis"] = "vertical" }
        if axes == Set([CaptureScrollAxis.horizontal, .vertical]) { result["scrollAxis"] = "both" }
        return result
    }

    private static func rect(_ rect: CaptureEdgeRect) -> [String: Any] {
        ["x": rect.left, "y": rect.top, "w": rect.width, "h": rect.height]
    }

}
