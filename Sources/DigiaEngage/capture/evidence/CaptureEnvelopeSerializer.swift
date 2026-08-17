import Foundation

internal enum CaptureEnvelopeSerializer {
    internal static func jsonBytes(_ envelope: PageCaptureEnvelopeV1) -> Data? {
        let wire = CaptureEnvelopeWire(
            schemaVersion: PageCaptureEnvelopeV1.captureSchemaVersion,
            pageKey: envelope.pageKey,
            binding: envelope.binding,
            platform: envelope.devicePlatform.rawValue,
            unit: "logicalPx",
            pixelScale: envelope.source.density,
            orientation: envelope.source.orientation.rawValue,
            layoutDirection: envelope.source.layoutDirection.rawValue,
            window: rect(envelope.source.windowBoundsPx),
            appContent: rect(envelope.source.appContentBoundsPx),
            screenshot: CaptureScreenshotWire(
                unit: "physicalPx",
                widthPx: envelope.screenshotSizePx.width,
                heightPx: envelope.screenshotSizePx.height
            ),
            appVersion: envelope.appVersion,
            appBuildNumber: envelope.appBuildNumber,
            sdkVersion: envelope.sdkVersion,
            captureProfile: CaptureProfileWire(
                includeText: envelope.profile.includeText,
                includeImagesAndMedia: envelope.profile.includeImagesAndMedia,
                includeOtherStructuralNodes: envelope.profile.includeOtherStructuralNodes
            ),
            traversal: CaptureTraversalWire(
                elapsedMs: envelope.traversal.elapsedMs,
                visitedNodeCount: envelope.traversal.visitedNodeCount,
                capturedNodeCount: envelope.traversal.capturedNodeCount
            ),
            nodes: envelope.nodes.map {
                CaptureNodeWire(
                    id: $0.nodeId,
                    parentId: $0.parentId,
                    childIndex: $0.childIndex,
                    rect: rect($0.rootBoundsPx),
                    viewportVisibility: $0.fullyVisible ? "fullyVisible" : "partiallyVisible",
                    nodeType: $0.nodeType.rawValue,
                    scrollAxis: $0.scrollAxis?.rawValue
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(wire)
    }

    private static func rect(_ rect: CaptureEdgeRect) -> CaptureRectWire {
        CaptureRectWire(x: rect.left, y: rect.top, w: rect.width, h: rect.height)
    }
}

private struct CaptureEnvelopeWire: Encodable {
    let schemaVersion: Int
    let pageKey: String
    let binding: String
    let platform: String
    let unit: String
    let pixelScale: Double
    let orientation: String
    let layoutDirection: String
    let window: CaptureRectWire
    let appContent: CaptureRectWire
    let screenshot: CaptureScreenshotWire
    let appVersion: String
    let appBuildNumber: String
    let sdkVersion: String
    let captureProfile: CaptureProfileWire
    let traversal: CaptureTraversalWire
    let nodes: [CaptureNodeWire]
}

private struct CaptureRectWire: Encodable {
    let x: Int
    let y: Int
    let w: Int
    let h: Int
}

private struct CaptureScreenshotWire: Encodable {
    let unit: String
    let widthPx: Int
    let heightPx: Int
}

private struct CaptureProfileWire: Encodable {
    let includeText: Bool
    let includeImagesAndMedia: Bool
    let includeOtherStructuralNodes: Bool
}

private struct CaptureTraversalWire: Encodable {
    let elapsedMs: Double
    let visitedNodeCount: Int
    let capturedNodeCount: Int
}

private struct CaptureNodeWire: Encodable {
    let id: String
    let parentId: String?
    let childIndex: Int
    let rect: CaptureRectWire
    let viewportVisibility: String
    let nodeType: String
    let scrollAxis: String?

    private enum CodingKeys: String, CodingKey {
        case id, parentId, childIndex, rect, viewportVisibility, nodeType, scrollAxis
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        if let parentId {
            try values.encode(parentId, forKey: .parentId)
        } else {
            try values.encodeNil(forKey: .parentId)
        }
        try values.encode(childIndex, forKey: .childIndex)
        try values.encode(rect, forKey: .rect)
        try values.encode(viewportVisibility, forKey: .viewportVisibility)
        try values.encode(nodeType, forKey: .nodeType)
        try values.encodeIfPresent(scrollAxis, forKey: .scrollAxis)
    }
}
