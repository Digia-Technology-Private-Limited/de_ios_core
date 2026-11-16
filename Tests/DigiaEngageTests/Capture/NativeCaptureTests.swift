import Foundation
import Testing
import UIKit
@testable import DigiaEngage

/// Page capture for plain native apps: which hosts may capture and how a capture is labelled,
/// and how a SwiftUI hosting view's content is reached through its accessibility tree.
@MainActor
@Suite("Native capture", .serialized, .tags(.capture, .unit))
struct NativeCaptureTests {
    private static let window = CaptureEdgeRect(left: 0, top: 0, right: 800, bottom: 600)
    private static let everything = CaptureProfile(
        includeText: true, includeImagesAndMedia: true, includeOtherStructuralNodes: true
    )

    // MARK: - Which hosts capture, and the binding they report

    @Test("a plain native app captures as native")
    func nativeBinding() {
        #expect(SDKInstance.captureBinding(forWrapperBinding: nil) == "native")
    }

    @Test("the React Native wrapper captures as reactNative")
    func reactNativeBinding() {
        #expect(SDKInstance.captureBinding(forWrapperBinding: "react_native") == "reactNative")
    }

    @Test("any other wrapper cannot capture")
    func otherWrapperCannotCapture() {
        #expect(SDKInstance.captureBinding(forWrapperBinding: "flutter") == nil)
        #expect(SDKInstance.captureBinding(forWrapperBinding: "") == nil)
    }

    @Test("a native capture is uploaded with binding native and platform ios")
    func nativeEnvelopeWire() throws {
        let binding = try #require(SDKInstance.captureBinding(forWrapperBinding: nil))
        let envelope = PageCaptureEnvelopeV1(
            pageKey: "home",
            binding: binding,
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
            traversal: CaptureTraversalFacts(elapsedMs: 1, visitedNodeCount: 1, capturedNodeCount: 1),
            nodes: [
                CaptureStructuralNode(
                    nodeId: "0", parentId: nil, childIndex: 0,
                    rootBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 10, bottom: 10),
                    fullyVisible: true, nodeType: .interactive, scrollAxis: nil
                ),
            ]
        )
        let data = try #require(CaptureEnvelopeSerializer.jsonBytes(envelope))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["binding"] as? String == "native")
        #expect(json["platform"] as? String == "ios")
    }

    // MARK: - SwiftUI content through the accessibility tree

    @Test("a hosting view's accessibility elements become nodes with their kind and bounds")
    func hostingViewElementsBecomeNodes() async {
        let host = FakeHostingView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        host.accessibilityElements = [
            element(in: host, CGRect(x: 10, y: 10, width: 100, height: 40), .button),
            element(in: host, CGRect(x: 10, y: 60, width: 200, height: 20), .staticText),
            element(in: host, CGRect(x: 10, y: 90, width: 50, height: 50), .image),
        ]

        let kept = nodes(await walk(host, profile: Self.everything))

        let button = ofType(kept, .interactive)
        #expect(button.count == 1)
        #expect(button.first?.rootBoundsPx == CaptureEdgeRect(left: 10, top: 10, right: 110, bottom: 50))
        #expect(ofType(kept, .text).count == 1)
        #expect(ofType(kept, .image).count == 1)
    }

    @Test("a header is text and a link is interactive")
    func headerAndLink() async {
        let host = FakeHostingView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        host.accessibilityElements = [
            element(in: host, CGRect(x: 0, y: 0, width: 100, height: 20), .header),
            element(in: host, CGRect(x: 0, y: 30, width: 100, height: 20), .link),
        ]

        let kept = nodes(await walk(host, profile: Self.everything))

        #expect(ofType(kept, .text).count == 1)
        #expect(ofType(kept, .interactive).count == 1)
    }

    @Test("nested accessibility containers are walked")
    func nestedContainers() async {
        let host = FakeHostingView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let group = UIAccessibilityElement(accessibilityContainer: host)
        group.accessibilityFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        group.accessibilityElements = [
            element(in: group, CGRect(x: 20, y: 20, width: 80, height: 30), .button),
        ]
        host.accessibilityElements = [group]

        let kept = nodes(await walk(host, profile: Self.everything))

        #expect(ofType(kept, .interactive).count == 1)
        #expect(ofType(kept, .container).contains {
            $0.rootBoundsPx == CaptureEdgeRect(left: 0, top: 0, right: 400, bottom: 300)
        })
    }

    @Test("a hidden accessibility element is not kept")
    func hiddenElementDropped() async {
        let host = FakeHostingView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let hidden = element(in: host, CGRect(x: 10, y: 10, width: 100, height: 40), .button)
        hidden.accessibilityElementsHidden = true
        host.accessibilityElements = [
            hidden,
            element(in: host, CGRect(x: 10, y: 60, width: 100, height: 40), .button),
        ]

        let kept = nodes(await walk(host, profile: Self.everything))

        #expect(ofType(kept, .interactive).count == 1)
        #expect(ofType(kept, .interactive).first?.rootBoundsPx.top == 60)
    }

    @Test("a hidden hosting view keeps none of its accessibility elements")
    func hiddenHostDropsElements() async {
        let host = FakeHostingView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        host.accessibilityElements = [
            element(in: host, CGRect(x: 10, y: 10, width: 100, height: 40), .button),
        ]
        host.isHidden = true
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        root.addSubview(host)
        let visible = UIControl(frame: CGRect(x: 0, y: 500, width: 50, height: 50))
        root.addSubview(visible)

        let kept = nodes(await CaptureEvidenceWalker.walk(
            root: UIKitCaptureNode(view: root, rootView: root),
            windowBoundsPx: Self.window,
            profile: Self.everything
        ))

        #expect(ofType(kept, .interactive).count == 1)
        #expect(ofType(kept, .interactive).first?.rootBoundsPx.top == 500)
    }

    @Test("a UIView listed as an accessibility element is walked once, as a subview")
    func viewElementNotDuplicated() async {
        let host = FakeHostingView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let control = UIControl(frame: CGRect(x: 10, y: 10, width: 100, height: 40))
        host.addSubview(control)
        host.accessibilityElements = [control]

        let kept = nodes(await walk(host, profile: Self.everything))

        #expect(ofType(kept, .interactive).count == 1)
    }

    @Test("a plain UIKit container's accessibility elements are not walked")
    func plainContainerUnchanged() async {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        container.accessibilityElements = [
            element(in: container, CGRect(x: 10, y: 10, width: 100, height: 40), .button),
        ]
        container.addSubview(UIControl(frame: CGRect(x: 10, y: 300, width: 100, height: 40)))

        let kept = nodes(await walk(container, profile: Self.everything))

        #expect(ofType(kept, .interactive).count == 1)
        #expect(ofType(kept, .interactive).first?.rootBoundsPx.top == 300)
    }

    @Test("SwiftUI hosting view classes are recognised by name")
    func hostingClassRecognised() {
        #expect(AccessibilityCaptureNode.exposesContentThroughAccessibility(FakeHostingView()))
        #expect(!AccessibilityCaptureNode.exposesContentThroughAccessibility(UIView()))
        #expect(!AccessibilityCaptureNode.exposesContentThroughAccessibility(UILabel()))
    }

    // MARK: - Helpers

    private func element(
        in container: Any,
        _ frame: CGRect,
        _ traits: UIAccessibilityTraits
    ) -> UIAccessibilityElement {
        let element = UIAccessibilityElement(accessibilityContainer: container)
        element.accessibilityFrame = frame
        element.accessibilityTraits = traits
        element.isAccessibilityElement = true
        return element
    }

    private func walk(_ root: UIView, profile: CaptureProfile) async -> CaptureWalkResult {
        await CaptureEvidenceWalker.walk(
            root: UIKitCaptureNode(view: root, rootView: root),
            windowBoundsPx: Self.window,
            profile: profile
        )
    }

    private func nodes(_ result: CaptureWalkResult) -> [CaptureStructuralNode] {
        guard case let .succeeded(nodes, _) = result else {
            Issue.record("expected a successful walk, got \(result)")
            return []
        }
        return nodes
    }

    private func ofType(
        _ all: [CaptureStructuralNode],
        _ type: CaptureNodeType
    ) -> [CaptureStructuralNode] {
        all.filter { $0.nodeType == type }
    }
}

/// Stands in for SwiftUI's hosting view, whose content is only visible through its
/// accessibility tree.
private final class FakeHostingView: UIView, CaptureAccessibilityHost {}
