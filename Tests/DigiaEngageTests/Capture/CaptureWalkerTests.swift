import Foundation
import Testing
import UIKit
@testable import DigiaEngage

/// What page capture reports about a screen: which views it keeps, how it classifies them, and
/// where they sit. Port of flutter/core `test/capture_walker_test.dart`.
///
/// Each test builds the view tree it wants out of UIKit views at known positions on an 800x600
/// root and walks it through `UIKitCaptureNode`, the way capture does. A `UIControl` stands in for
/// a button, a `UILabel` for text and a `UIImageView` for an image.
@MainActor
@Suite("Capture walker", .serialized, .tags(.capture, .component))
struct CaptureWalkerTests {
    private static let window = CaptureEdgeRect(left: 0, top: 0, right: 800, bottom: 600)
    private static let everything = CaptureProfile(
        includeText: true, includeImagesAndMedia: true, includeOtherStructuralNodes: true
    )

    // MARK: - What is kept

    private func mixed() -> [UIView] {
        [
            box(10, 10, 100, 40, .button),
            box(10, 60, 200, 20, .text),
            box(10, 90, 50, 50, .image),
        ]
    }

    @Test("an interactive node is always kept")
    func interactiveAlwaysKept() async {
        let kept = nodes(await walk(mixed()))

        #expect(ofType(kept, .interactive).count == 1)
    }

    @Test("text, images and structure are kept only when asked for")
    func profileSelectsKinds() async {
        let none = nodes(await walk(mixed()))
        #expect(ofType(none, .text).isEmpty)
        #expect(ofType(none, .image).isEmpty)

        let text = nodes(await walk(mixed(), profile: CaptureProfile(
            includeText: true, includeImagesAndMedia: false, includeOtherStructuralNodes: false
        )))
        #expect(ofType(text, .text).count == 1)
        #expect(ofType(text, .image).isEmpty)

        let images = nodes(await walk(mixed(), profile: CaptureProfile(
            includeText: false, includeImagesAndMedia: true, includeOtherStructuralNodes: false
        )))
        #expect(ofType(images, .image).count == 1)
        #expect(ofType(images, .text).isEmpty)

        let all = nodes(await walk(mixed(), profile: Self.everything))
        #expect(ofType(all, .text).count == 1)
        #expect(ofType(all, .image).count == 1)
    }

    @Test("a node nothing could tap is structure, kept only when structure is asked for")
    func structureOnlyWhenAsked() async {
        // A group that leads to nothing tappable.
        let children = { [
            self.box(10, 10, 100, 40, .button),
            self.box(0, 100, 400, 200, children: [self.box(10, 10, 100, 40, .text)]),
        ] }

        let bare = nodes(await walk(children()))
        let structural = nodes(await walk(children(), profile: CaptureProfile(
            includeText: false, includeImagesAndMedia: false, includeOtherStructuralNodes: true
        )))

        #expect(structural.count > bare.count)
        #expect(ofType(structural, .container).count > ofType(bare, .container).count)
        #expect(ofType(structural, .text).isEmpty, "structure does not bring the words with it")
    }

    @Test("a kept node brings the ancestors it hangs from, so the tree stays connected")
    func keptNodeBringsAncestors() async throws {
        let kept = nodes(await walk([
            box(0, 0, 400, 300, children: [box(10, 10, 100, 40, .button)]),
        ]))

        let button = try #require(ofType(kept, .interactive).first)
        let parentId = try #require(button.parentId)
        let parent = try #require(kept.first { $0.nodeId == parentId })
        #expect(parent.nodeType != .interactive)
        #expect(Set(kept.map(\.nodeId)).count == kept.count)
    }

    @Test("a screen with nothing capturable is refused")
    func nothingCapturableIsRefused() async {
        let result = await walk([box(10, 60, 200, 20, .text)])

        #expect(refusal(result) == .noCapturableNodes)
    }

    // MARK: - Where a node is

    @Test("is its rectangle relative to the root")
    func rectangleRelativeToRoot() async throws {
        let kept = nodes(await walk([
            box(20, 30, 400, 300, children: [box(10, 10, 120, 60, .button)]),
        ]))

        let rect = try #require(ofType(kept, .interactive).first).rootBoundsPx
        #expect(rect == CaptureEdgeRect(left: 30, top: 40, right: 150, bottom: 100))
    }

    @Test("is fully visible when it lies inside the window")
    func fullyVisibleInsideWindow() async throws {
        let kept = nodes(await walk([box(30, 40, 120, 60, .button)]))

        #expect(try #require(ofType(kept, .interactive).first).fullyVisible)
    }

    @Test("is partly visible when the window cuts it, and keeps its whole rectangle")
    func partlyVisibleKeepsWholeRect() async throws {
        let kept = nodes(await walk(
            [box(30, 40, 120, 60, .button)],
            window: CaptureEdgeRect(left: 0, top: 0, right: 800, bottom: 60)
        ))

        let button = try #require(ofType(kept, .interactive).first)
        #expect(!button.fullyVisible)
        #expect(button.rootBoundsPx.height == 60)
    }

    @Test("is left out when it lies wholly outside the window")
    func outsideWindowLeftOut() async {
        let result = await walk(
            [box(30, 40, 120, 60, .button), box(30, 200, 120, 60, .button)],
            window: CaptureEdgeRect(left: 0, top: 0, right: 800, bottom: 100)
        )

        #expect(ofType(nodes(result), .interactive).count == 1)
    }

    @Test("is left out when it touches the window only along an edge")
    func edgeTouchLeftOut() async {
        let result = await walk(
            [box(30, 40, 120, 60, .button), box(30, 100, 120, 60, .button)],
            window: CaptureEdgeRect(left: 0, top: 0, right: 800, bottom: 100)
        )

        #expect(ofType(nodes(result), .interactive).count == 1)
    }

    @Test("is left out when it, or an ancestor, is hidden or fully transparent")
    func hiddenLeftOut() async {
        let hidden = box(30, 200, 120, 60, .button)
        hidden.isHidden = true
        let transparent = box(30, 300, 120, 60, .button)
        transparent.alpha = 0
        let hiddenParent = box(200, 0, 300, 300, children: [box(10, 10, 100, 40, .button)])
        hiddenParent.isHidden = true

        let result = await walk([box(30, 40, 120, 60, .button), hidden, transparent, hiddenParent])

        #expect(ofType(nodes(result), .interactive).count == 1)
    }

    // MARK: - The order and the tree

    @Test("siblings are numbered in order under their parent")
    func siblingsNumberedInOrder() async {
        let kept = nodes(await walk([
            box(10, 10, 100, 40, .button),
            box(10, 60, 100, 40, .button),
            box(10, 110, 100, 40, .button),
        ]))

        #expect(ofType(kept, .interactive).count == 3)
        let byParent = Dictionary(grouping: kept, by: \.parentId).mapValues { $0.map(\.childIndex) }
        for indexes in byParent.values {
            #expect(indexes == Array(0..<indexes.count), "child indexes run 0, 1, 2 ...")
        }
    }

    @Test("a node without a visible parent is attached to its nearest visible ancestor")
    func attachesToNearestVisibleAncestor() async throws {
        // The middle view has no size, so it is not visible, yet its child is.
        let kept = nodes(await walk([
            box(0, 0, 400, 300, children: [
                box(0, 0, 0, 0, children: [box(10, 10, 100, 40, .button)]),
            ]),
        ]))

        let ids = Set(kept.map(\.nodeId))
        for node in kept {
            if let parentId = node.parentId { #expect(ids.contains(parentId), "\(node.nodeId)") }
        }
        let button = try #require(ofType(kept, .interactive).first)
        #expect(button.nodeId == "0.0.0.0")
        #expect(button.parentId == "0.0")
    }

    // MARK: - One element, one node

    @Test("a view that shares its parent's rectangle is merged into it, not reported twice")
    func sameRectParentAndChildMerge() async throws {
        let kept = nodes(await walk([
            box(10, 10, 100, 40, .button, children: [
                box(0, 0, 100, 40, .button, children: [box(0, 0, 100, 40)]),
            ]),
        ]))

        let buttons = ofType(kept, .interactive)
        #expect(buttons.count == 1, "the wrapper chain is one control")
        #expect(kept.filter { $0.rootBoundsPx.width == 100 }.count == 1, "no wrapper of the same size is left")
    }

    @Test("a merged node's children move to the node it merged into, keeping ids and indexes consistent")
    func mergedChildrenAreReparented() async throws {
        let kept = nodes(await walk([
            box(0, 0, 300, 200, children: [
                box(0, 0, 300, 200, children: [
                    box(10, 10, 100, 40, .button),
                    box(10, 60, 100, 40, .button),
                ]),
            ]),
        ]))

        let ids = Set(kept.map(\.nodeId))
        #expect(ids.count == kept.count, "ids stay unique")
        for node in kept {
            if let parentId = node.parentId { #expect(ids.contains(parentId), "\(node.nodeId) has a parent") }
        }
        let buttons = ofType(kept, .interactive)
        #expect(buttons.count == 2)
        #expect(Set(buttons.map(\.parentId)).count == 1, "both buttons hang from the same node")
        #expect(buttons.map(\.childIndex).sorted() == [0, 1])
    }

    @Test("a merged pair keeps the more meaningful type")
    func mergedPairKeepsMostMeaningfulType() async throws {
        let kept = nodes(await walk([
            box(10, 10, 100, 40, children: [box(0, 0, 100, 40, .button)]),
            box(10, 100, 100, 40, children: [box(0, 0, 100, 40, .text)]),
        ], profile: Self.everything))

        #expect(ofType(kept, .interactive).count == 1)
        #expect(ofType(kept, .text).count == 1)
        #expect(kept.filter { $0.rootBoundsPx.top == 10 }.count == 1)
        #expect(kept.filter { $0.rootBoundsPx.top == 100 }.count == 1)
    }

    @Test("two different meaningful elements that share a size are both kept")
    func distinctMeaningfulElementsNeverMerge() async throws {
        let kept = nodes(await walk([
            box(10, 10, 100, 40, .button, children: [box(0, 0, 100, 40, .text), box(0, 0, 100, 40, .image)]),
        ], profile: Self.everything))

        #expect(ofType(kept, .interactive).count == 1)
        #expect(ofType(kept, .text).count == 1, "the label is not swallowed by the button")
        #expect(ofType(kept, .image).count == 1, "the icon is not swallowed by the button")
    }

    @Test("a rectangle within a point of its parent's is the same rectangle, two points is not")
    func mergeToleranceIsOnePoint() async throws {
        let kept = nodes(await walk([
            box(10, 10, 100, 40, .button, children: [box(0, 0, 101, 40, .button)]),
            box(10, 100, 100, 40, .button, children: [box(0, 0, 102, 40, .button)]),
        ]))

        #expect(kept.filter { $0.rootBoundsPx.top == 10 }.count == 1)
        #expect(kept.filter { $0.rootBoundsPx.top == 100 }.count == 2)
    }

    @Test("a switch is one interactive node, not the switch and a copy of it")
    func switchIsOneNode() async throws {
        let toggle = UISwitch(frame: CGRect(x: 10, y: 10, width: 51, height: 31))

        let kept = nodes(await walk([toggle]))
        let frame = toggle.frame

        let atSwitch = kept.filter { node in
            node.nodeType == .interactive &&
                abs(node.rootBoundsPx.left - Int(frame.minX.rounded())) <= 1 &&
                abs(node.rootBoundsPx.top - Int(frame.minY.rounded())) <= 1 &&
                abs(node.rootBoundsPx.right - Int(frame.maxX.rounded())) <= 1 &&
                abs(node.rootBoundsPx.bottom - Int(frame.maxY.rounded())) <= 1
        }
        #expect(atSwitch.count == 1, "interactive nodes at the switch: \(atSwitch.map(\.nodeId))")
    }

    @Test("a view with a tap gesture is interactive, one with only UIKit's own plumbing is not")
    func gestureMakesInteractive() async throws {
        let tappable = box(10, 10, 100, 40)
        tappable.addGestureRecognizer(UITapGestureRecognizer())
        let plumbing = box(10, 100, 100, 40)
        plumbing.addGestureRecognizer(PlumbingGestureRecognizer())

        let kept = nodes(await walk([tappable, plumbing]))

        #expect(ofType(kept, .interactive).map(\.rootBoundsPx.top) == [10])
    }

    // MARK: - Scrolling

    @Test("a scroll view is a scroll container, kept without being asked for", arguments: [
        (CGSize(width: 300, height: 2000), CaptureScrollAxis.vertical),
        (CGSize(width: 2000, height: 200), CaptureScrollAxis.horizontal),
        (CGSize(width: 2000, height: 2000), CaptureScrollAxis.both),
    ])
    func scrollContainer(contentSize: CGSize, axis: CaptureScrollAxis) async throws {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = contentSize

        let kept = nodes(await walk([scroll, box(400, 10, 100, 40, .button)]))

        let scrolling = kept.filter { $0.scrollAxis != nil }
        #expect(scrolling.count == 1)
        let node = try #require(scrolling.first)
        #expect(node.scrollAxis == axis)
        #expect(node.nodeType == .container)
    }

    @Test("a node that is not a scroll container has no axis")
    func noScrollAxis() async {
        let fitting = UIScrollView(frame: CGRect(x: 0, y: 200, width: 300, height: 200))
        fitting.contentSize = CGSize(width: 300, height: 200)

        let kept = nodes(await walk([box(10, 10, 100, 40, .button), fitting], profile: Self.everything))

        #expect(kept.allSatisfy { $0.scrollAxis == nil })
    }

    // MARK: - Refusing

    @Test("stops when the caller cancels")
    func cancelled() async {
        let result = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await self.walk([self.box(10, 10, 100, 40, .button)])
        }.value

        #expect(refusal(result) == .cancelled)
    }

    @Test("gives up when the half-second budget is spent", .tags(.slow))
    func timeBudgetExceeded() async {
        let result = await CaptureEvidenceWalker.walk(
            root: StallingNode(child: UIKitCaptureNode(view: box(10, 10, 100, 40, .button), rootView: UIView())),
            windowBoundsPx: Self.window,
            profile: .minimal
        )

        #expect(refusal(result) == .timeBudgetExceeded)
    }

    @Test("prefers saying it was cancelled to saying it was slow", .tags(.slow))
    func cancellationBeatsBudget() async {
        let result = await Task { @MainActor in
            await CaptureEvidenceWalker.walk(
                root: StallingNode(
                    child: UIKitCaptureNode(view: self.box(10, 10, 100, 40, .button), rootView: UIView()),
                    cancelWhileStalling: true
                ),
                windowBoundsPx: Self.window,
                profile: .minimal
            )
        }.value

        #expect(refusal(result) == .cancelled)
    }

    // MARK: - Its diagnostics

    @Test("count what was visited and what was kept")
    func diagnosticsCounts() async throws {
        let result = await walk([
            box(10, 10, 100, 40, .button),
            box(10, 60, 100, 40, .button),
            box(10, 110, 100, 20, .text),
        ])

        guard case let .succeeded(kept, traversal) = result else {
            Issue.record("expected a successful walk, got \(result)")
            return
        }
        #expect(traversal.capturedNodeCount == kept.count)
        #expect(traversal.visitedNodeCount >= traversal.capturedNodeCount)
        #expect(traversal.visitedNodeCount > 3)
        #expect(traversal.elapsedMs >= 0)
    }

    @Test("are given for a refusal too")
    func diagnosticsOnRefusal() async {
        let result = await walk([box(10, 60, 200, 20, .text)])

        guard case let .refused(_, traversal) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(traversal.visitedNodeCount > 0)
        #expect(traversal.capturedNodeCount == 0)
    }

    // MARK: - A busy screen

    @Test("is walked in full, yielding between batches")
    func busyScreen() async {
        let children = (0..<400).map { i in
            box(CGFloat(i % 20) * 38, CGFloat(i / 20) * 28, 36, 26, .button)
        }

        let result = await walk(children)

        #expect(ofType(nodes(result), .interactive).count == 400)
    }

    // MARK: - Helpers

    private enum Kind { case plain, button, text, image }

    private func box(
        _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
        _ kind: Kind = .plain,
        children: [UIView] = []
    ) -> UIView {
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let view: UIView
        switch kind {
        case .plain: view = UIView(frame: frame)
        case .button: view = UIControl(frame: frame)
        case .text: view = UILabel(frame: frame)
        case .image: view = UIImageView(frame: frame)
        }
        children.forEach(view.addSubview)
        return view
    }

    private func walk(
        _ children: [UIView],
        profile: CaptureProfile = .minimal,
        window: CaptureEdgeRect = CaptureWalkerTests.window
    ) async -> CaptureWalkResult {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        children.forEach(root.addSubview)
        return await CaptureEvidenceWalker.walk(
            root: UIKitCaptureNode(view: root, rootView: root),
            windowBoundsPx: window,
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

    private func refusal(_ result: CaptureWalkResult) -> CaptureWalkRefusal? {
        guard case let .refused(reason, _) = result else { return nil }
        return reason
    }

    private func ofType(_ all: [CaptureStructuralNode], _ type: CaptureNodeType) -> [CaptureStructuralNode] {
        all.filter { $0.nodeType == type }
    }
}

/// Stands in for UIKit's own recognizers (`_UIParallaxTransitionPanGestureRecognizer`), which no
/// app installed and which do not make their view a control.
@objc(_PlumbingGestureRecognizer)
private final class PlumbingGestureRecognizer: UIGestureRecognizer {}

/// A root that stalls past the walker's half-second budget while handing over its children,
/// so the budget check before the next node fires. Optionally cancels the walking task first.
@MainActor
private struct StallingNode: CaptureNodeSource {
    let child: CaptureNodeSource
    var cancelWhileStalling = false

    var childNodes: [CaptureNodeSource] {
        if cancelWhileStalling { withUnsafeCurrentTask { $0?.cancel() } }
        Thread.sleep(forTimeInterval: 0.55)
        return [child]
    }

    var rootBounds: CaptureEdgeRect { CaptureEdgeRect(left: 0, top: 0, right: 800, bottom: 600) }
    var shown: Bool { true }
    var alpha: Double { 1 }
    var nodeType: CaptureNodeType { .container }
    var scrollAxis: CaptureScrollAxis? { nil }
}
