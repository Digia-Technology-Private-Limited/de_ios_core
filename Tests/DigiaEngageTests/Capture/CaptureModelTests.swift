import Foundation
import Testing
@testable import DigiaEngage

/// Port of flutter/core `test/capture_model_test.dart`. On iOS a node reaches the wire only through
/// `CaptureEnvelopeSerializer`, so the node shape is pinned on a serialized envelope.
@Suite("Capture model", .tags(.capture, .contract))
struct CaptureModelTests {

    @Test("rect intersection pins visibility boundaries")
    func intersectionBoundaries() {
        let viewport = rect(x: 0, y: 0, w: 100, h: 100)

        #expect(rect(x: 0, y: 0, w: 100, h: 100).intersection(viewport) == rect(x: 0, y: 0, w: 100, h: 100))
        #expect(rect(x: 99, y: 10, w: 20, h: 20).intersection(viewport) == rect(x: 99, y: 10, w: 1, h: 20))
        #expect(rect(x: 100, y: 10, w: 20, h: 20).intersection(viewport) == nil)
        #expect(rect(x: 10, y: -20, w: 20, h: 21).intersection(viewport) == rect(x: 10, y: 0, w: 20, h: 1))
    }

    @Test("a node exposes geometry and type but no semantic text or media")
    func nodeWireShape() throws {
        let envelope = try serialized(nodes: [
            CaptureStructuralNode(
                nodeId: "0.1", parentId: "0", childIndex: 1,
                rootBoundsPx: rect(x: 5, y: 6, w: 7, h: 8),
                fullyVisible: false, nodeType: .text, scrollAxis: .vertical
            ),
        ])

        let node = try #require((envelope["nodes"] as? [[String: Any]])?.first)
        #expect(node as NSDictionary == [
            "id": "0.1",
            "parentId": "0",
            "childIndex": 1,
            "rect": ["x": 5, "y": 6, "w": 7, "h": 8],
            "viewportVisibility": "partiallyVisible",
            "nodeType": "text",
            "scrollAxis": "vertical",
        ] as NSDictionary)
        #expect(node["text"] == nil)
        #expect(node["value"] == nil)
        #expect(node["src"] == nil)
    }

    @Test("a root node writes parentId as null and leaves out a missing scroll axis")
    func rootNodeWireShape() throws {
        let envelope = try serialized(nodes: [
            CaptureStructuralNode(
                nodeId: "0.0", parentId: nil, childIndex: 0,
                rootBoundsPx: rect(x: 4, y: 8, w: 20, h: 10),
                fullyVisible: true, nodeType: .interactive, scrollAxis: nil
            ),
        ])

        let node = try #require((envelope["nodes"] as? [[String: Any]])?.first)
        #expect(node as NSDictionary == [
            "id": "0.0",
            "parentId": NSNull(),
            "childIndex": 0,
            "rect": ["x": 4, "y": 8, "w": 20, "h": 10],
            "viewportVisibility": "fullyVisible",
            "nodeType": "interactive",
        ] as NSDictionary)
    }

    @Test("the envelope states its units, scale, screenshot size and profile")
    func envelopeHeader() throws {
        let envelope = try serialized(nodes: [])

        #expect(envelope["schemaVersion"] as? Int == 1)
        #expect(envelope["unit"] as? String == "logicalPx")
        #expect(envelope["pixelScale"] as? Double == 3)
        #expect(envelope["window"] as? NSDictionary == ["x": 0, "y": 0, "w": 100, "h": 200] as NSDictionary)
        #expect(envelope["appContent"] as? NSDictionary == ["x": 0, "y": 10, "w": 100, "h": 180] as NSDictionary)
        #expect(envelope["screenshot"] as? NSDictionary == [
            "unit": "physicalPx", "widthPx": 300, "heightPx": 600,
        ] as NSDictionary)
        #expect(envelope["captureProfile"] as? NSDictionary == [
            "includeText": false, "includeImagesAndMedia": false, "includeOtherStructuralNodes": false,
        ] as NSDictionary)
    }

    private func serialized(nodes: [CaptureStructuralNode]) throws -> [String: Any] {
        let data = try #require(CaptureEnvelopeSerializer.jsonBytes(CaptureFixtures.envelope(nodes: nodes)))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func rect(x: Int, y: Int, w: Int, h: Int) -> CaptureEdgeRect {
        CaptureEdgeRect(left: x, top: y, right: x + w, bottom: y + h)
    }
}

enum CaptureFixtures {
    static func envelope(nodes: [CaptureStructuralNode] = []) -> PageCaptureEnvelopeV1 {
        PageCaptureEnvelopeV1(
            pageKey: "home",
            binding: "native",
            devicePlatform: .ios,
            source: CaptureSourceFrame(
                density: 3,
                windowBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 100, bottom: 200),
                appContentBoundsPx: CaptureEdgeRect(left: 0, top: 10, right: 100, bottom: 190),
                orientation: .portrait,
                layoutDirection: .ltr
            ),
            screenshotSizePx: CaptureSize(width: 300, height: 600),
            appVersion: "1.0.0",
            appBuildNumber: "1",
            sdkVersion: "test",
            profile: .minimal,
            traversal: CaptureTraversalFacts(elapsedMs: 12, visitedNodeCount: 2, capturedNodeCount: 1),
            nodes: nodes
        )
    }
}
