import Foundation
import XCTest
@testable import DigiaEngage

final class CaptureEvidenceTests: XCTestCase {
    @MainActor
    func testNodeLimitIsHonest() {
        let root = SyntheticCaptureNode(children: (0..<3_000).map { _ in SyntheticCaptureNode() })
        let result = CaptureEvidenceWalker.walk(
            root: root,
            windowBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 100, bottom: 100)
        )
        XCTAssertEqual(result.nodes.count, CaptureLimits.maxNodeCount)
        XCTAssertEqual(result.integrity.nodeCount, 2_000)
        XCTAssertEqual(result.integrity.maxDepth, 2)
        XCTAssertEqual(result.integrity.truncationReason, .nodeLimit)
        XCTAssertTrue(result.integrity.truncated)
    }

    @MainActor
    func testDepthLimitIsHonest() {
        var node = SyntheticCaptureNode()
        for _ in 0..<79 { node = SyntheticCaptureNode(children: [node]) }
        let result = CaptureEvidenceWalker.walk(
            root: node,
            windowBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 100, bottom: 100)
        )
        XCTAssertEqual(result.nodes.count, CaptureLimits.maxDepth)
        XCTAssertEqual(result.integrity.maxDepth, CaptureLimits.maxDepth)
        XCTAssertEqual(result.integrity.truncationReason, .depthLimit)
        XCTAssertTrue(result.integrity.truncated)
    }

    @MainActor
    func testOwnedSubtreeIsAbsentAndDoesNotConsumeSiblingIndex() {
        let root = SyntheticCaptureNode(children: [
            SyntheticCaptureNode(isDigiaOwned: true),
            SyntheticCaptureNode(),
        ])
        let result = CaptureEvidenceWalker.walk(
            root: root,
            windowBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 100, bottom: 100)
        )
        XCTAssertEqual(result.nodes.map(\.nodeId), ["0", "0.0"])
        XCTAssertFalse(result.nodes.contains { $0.nodeId == "0.1" })
    }

    @MainActor
    func testSerializerHasNoUnboundedObjectField() throws {
        let node = CaptureStructuralNode(
            nodeId: "0", parentId: nil, childIndex: 0, paintOrder: 0,
            localBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 1, bottom: 1),
            transformToRoot: .identity,
            rootBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 1, bottom: 1),
            visibleBoundsPx: nil, clipContainerId: nil, clipBoundsPx: nil,
            inheritedShown: true, effectiveAlpha: 1, visibleFraction: 1,
            visibilityState: .unclipped, containerTraits: [], scrollAxes: [],
            viewportBoundsPx: nil, scrollOffsetPx: nil, contentExtentPx: nil,
            scrollParentId: nil, virtualized: false, role: nil, supportedActions: [],
            enabled: true, selected: false, checked: nil, expanded: nil, focused: false,
            editable: false, hasText: false, renderedLineCount: 0,
            hasAccessibilityLabel: false, valid: true
        )
        let envelope = PageCaptureEnvelopeV1(
            pageKey: "home", capturedAt: "2026-08-06T00:00:00.000Z", devicePlatform: .ios,
            binding: .native,
            screenshot: CaptureScreenshotFacts(widthPx: 1, heightPx: 1, byteLength: 1, sha256: String(repeating: "0", count: 64)),
            source: CaptureSourceFrame(
                density: 1, windowBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 1, bottom: 1),
                appContentBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 1, bottom: 1),
                insetsPx: CaptureInsets(left: 0, top: 0, right: 0, bottom: 0), orientation: .portrait, layoutDirection: .ltr
            ),
            app: CaptureAppFacts(bundleIdentifier: "test", versionName: "1", buildNumber: "1"),
            runtime: CaptureRuntimeFacts(osVersion: "18", locale: "en-IN", fontScale: 1, sdkVersion: "3.9.0", wrapperVersion: nil, formFactor: .phone),
            nodes: [node], integrity: CaptureIntegrityFacts(nodeCount: 1, maxDepth: 1, truncated: false, truncationReason: nil)
        )
        let object = try XCTUnwrap(CaptureEnvelopeSerializer.jsonObject(envelope)["nodes"] as? [[String: Any]])
        XCTAssertEqual(object.first?.keys.sorted(), [
            "childIndex", "checked", "clipBoundsPx", "clipContainerId", "containerTraits",
            "contentExtentPx", "editable", "enabled", "expanded", "focused", "hasAccessibilityLabel",
            "hasText", "inheritedShown", "localBoundsPx", "nodeId", "paintOrder", "parentId",
            "react" + "Tag", "role", "rootBoundsPx", "scrollAxes", "scrollOffsetPx", "scrollParentId",
            "selected", "supportedActions", "transformToRoot", "valid", "viewportBoundsPx",
            "visibleBoundsPx", "visibleFraction", "visibilityState", "virtualized", "renderedLineCount",
        ].sorted().filter { $0 != "react" + "Tag" })
    }
}

@MainActor
private struct SyntheticCaptureNode: CaptureNodeSource {
    var children: [SyntheticCaptureNode] = []
    var isDigiaOwned = false

    var childNodes: [CaptureNodeSource] { children }
    var sizePx: CaptureSize { CaptureSize(width: 10, height: 10) }
    var transformToRoot: CaptureAffine { .identity }
    var shown: Bool { true }
    var ownAlpha: Double { 1 }
    var clipsChildren: Bool { false }
    var scroll: CaptureScrollFacts? { nil }
    var virtualized: Bool { false }
    var state: CaptureNodeState { .inert }
}
