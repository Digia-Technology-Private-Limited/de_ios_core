// Module: capture/evidence
//
// The one place an envelope becomes bytes.
//
// Written by hand, key by key, rather than synthesized by `Encodable`, and that is
// deliberate: the allowlist is auditable by reading one function top to bottom. A
// synthesized encoder would put on the wire whatever a future property happened to
// add, silently. This one puts on the wire exactly what §2 names, and a reviewer
// can diff it against `capture-allowlist-v1.json` line by line.
//
// There is no filtering step anywhere below, because there is nothing to filter:
// the types cannot carry a prohibited field.

import Foundation

internal enum CaptureEnvelopeSerializer {

    /// §2.1 — the `capture` JSON part of the multipart upload.
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

    /// Deterministic bytes: sorted keys, no escaped slashes. Two runs of the same
    /// capture produce the same bytes, so a digest over them means something.
    internal static func jsonBytes(_ envelope: PageCaptureEnvelopeV1) -> Data? {
        guard !envelope.integrity.truncated else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: jsonObject(envelope),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Minimal graph wire shape

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

    /// §2.6, in the group order the section lists.
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

    // MARK: - Wire shapes

    private static func rect(_ rect: CaptureEdgeRect) -> [String: Any] {
        ["x": rect.left, "y": rect.top, "w": rect.width, "h": rect.height]
    }

}
