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
            "captureSchemaVersion": PageCaptureEnvelopeV1.captureSchemaVersion,
            "allowlistVersion": PageCaptureEnvelopeV1.allowlistVersion,
            "pageKey": envelope.pageKey,
            "capturedAt": envelope.capturedAt,
            "devicePlatform": envelope.devicePlatform.rawValue,
            "binding": envelope.binding.rawValue,
            "screenshot": screenshot(envelope.screenshot),
            "source": source(envelope.source),
            "app": app(envelope.app),
            "runtime": runtime(envelope.runtime),
            "nodes": envelope.nodes.map(node),
            "integrity": integrity(envelope.integrity),
        ]
    }

    /// Deterministic bytes: sorted keys, no escaped slashes. Two runs of the same
    /// capture produce the same bytes, so a digest over them means something.
    internal static func jsonBytes(_ envelope: PageCaptureEnvelopeV1) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: jsonObject(envelope),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Objects

    private static func screenshot(_ facts: CaptureScreenshotFacts) -> [String: Any] {
        // No base-64 member, no source dimensions, no quality, no scale, no URL —
        // §2.2 and §8. The PNG is the multipart file part and is never inlined.
        [
            "mimeType": CaptureScreenshotFacts.mimeType,
            "widthPx": facts.widthPx,
            "heightPx": facts.heightPx,
            "byteLength": facts.byteLength,
            "sha256": facts.sha256,
        ]
    }

    private static func source(_ frame: CaptureSourceFrame) -> [String: Any] {
        [
            "density": frame.density,
            "windowBoundsPx": edgeRect(frame.windowBoundsPx),
            "appContentBoundsPx": edgeRect(frame.appContentBoundsPx),
            "insetsPx": [
                "left": frame.insetsPx.left,
                "top": frame.insetsPx.top,
                "right": frame.insetsPx.right,
                "bottom": frame.insetsPx.bottom,
            ],
            "orientation": frame.orientation.rawValue,
            "layoutDirection": frame.layoutDirection.rawValue,
        ]
    }

    private static func app(_ facts: CaptureAppFacts) -> [String: Any] {
        [
            "bundleIdentifier": facts.bundleIdentifier,
            "versionName": facts.versionName,
            "buildNumber": facts.buildNumber,
        ]
    }

    private static func runtime(_ facts: CaptureRuntimeFacts) -> [String: Any] {
        [
            "osVersion": facts.osVersion,
            "locale": facts.locale,
            "fontScale": facts.fontScale,
            "sdkVersion": facts.sdkVersion,
            "wrapperVersion": facts.wrapperVersion ?? NSNull(),
            "formFactor": facts.formFactor.rawValue,
        ]
    }

    private static func integrity(_ facts: CaptureIntegrityFacts) -> [String: Any] {
        [
            "nodeCount": facts.nodeCount,
            "maxDepth": facts.maxDepth,
            "truncated": facts.truncated,
            "truncationReason": facts.truncationReason?.rawValue ?? NSNull(),
        ]
    }

    /// §2.6, in the group order the section lists.
    private static func node(_ node: CaptureStructuralNode) -> [String: Any] {
        [
            // Topology
            "nodeId": node.nodeId,
            "parentId": node.parentId ?? NSNull(),
            "childIndex": node.childIndex,
            "paintOrder": node.paintOrder,
            // Geometry
            "localBoundsPx": edgeRect(node.localBoundsPx),
            "transformToRoot": affine(node.transformToRoot),
            "rootBoundsPx": edgeRect(node.rootBoundsPx),
            "visibleBoundsPx": node.visibleBoundsPx.map(edgeRect) ?? NSNull(),
            "clipContainerId": node.clipContainerId ?? NSNull(),
            "clipBoundsPx": node.clipBoundsPx.map(edgeRect) ?? NSNull(),
            // Visibility
            "inheritedShown": node.inheritedShown,
            "effectiveAlpha": node.effectiveAlpha,
            "visibleFraction": node.visibleFraction,
            "visibilityState": node.visibilityState.rawValue,
            // Containers
            "containerTraits": node.containerTraits.map(\.wireName),
            "scrollAxes": node.scrollAxes.map(\.rawValue),
            "viewportBoundsPx": node.viewportBoundsPx.map(edgeRect) ?? NSNull(),
            "scrollOffsetPx": node.scrollOffsetPx.map(point) ?? NSNull(),
            "contentExtentPx": node.contentExtentPx.map(size) ?? NSNull(),
            "scrollParentId": node.scrollParentId ?? NSNull(),
            "virtualized": node.virtualized,
            // Meaning
            "role": node.role?.wireName ?? NSNull(),
            "supportedActions": node.supportedActions.map(\.wireName),
            // Content-free state
            "enabled": node.enabled,
            "selected": node.selected,
            "checked": node.checked ?? NSNull(),
            "expanded": node.expanded ?? NSNull(),
            "focused": node.focused,
            "editable": node.editable,
            "hasText": node.hasText,
            "renderedLineCount": node.renderedLineCount,
            "hasAccessibilityLabel": node.hasAccessibilityLabel,
            // Integrity
            "valid": node.valid,
        ]
    }

    // MARK: - Value shapes

    private static func edgeRect(_ rect: CaptureEdgeRect) -> [String: Any] {
        ["left": rect.left, "top": rect.top, "right": rect.right, "bottom": rect.bottom]
    }

    private static func point(_ point: CapturePoint) -> [String: Any] {
        ["x": point.x, "y": point.y]
    }

    private static func size(_ size: CaptureSize) -> [String: Any] {
        ["width": size.width, "height": size.height]
    }

    private static func affine(_ transform: CaptureAffine) -> [String: Any] {
        [
            "a": transform.a,
            "b": transform.b,
            "c": transform.c,
            "d": transform.d,
            "tx": transform.tx,
            "ty": transform.ty,
        ]
    }
}
