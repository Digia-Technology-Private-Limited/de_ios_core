import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

// In the serialized DigiaEngage suite: these share AnchorRegistry.shared with
// its tests, which reset it.
extension DigiaEngageTests {
    private var registry: AnchorRegistry { AnchorRegistry.shared }

    @Test("UIKit anchor registers in a window and unregisters only its own view on leaving")
    func uikitAnchorWindowLifecycle() {
        let window = makeWindow()
        let anchor = DigiaAnchorView(frame: CGRect(x: 10, y: 10, width: 100, height: 40))
        anchor.anchorKey = "a30-lifecycle"
        #expect(registry.getView(for: "a30-lifecycle") == nil)

        window.addSubview(anchor)
        #expect(registry.getView(for: "a30-lifecycle") === anchor)

        let other = UIView(frame: CGRect(x: 10, y: 80, width: 100, height: 40))
        window.addSubview(other)
        registry.register(key: "a30-lifecycle", view: other)
        anchor.removeFromSuperview()
        #expect(registry.getView(for: "a30-lifecycle") === other)

        registry.unregister(key: "a30-lifecycle")
        other.removeFromSuperview()
    }

    @Test("changing anchorKey moves the registration to the new key")
    func uikitAnchorKeyChange() {
        let window = makeWindow()
        let anchor = DigiaAnchorView(frame: CGRect(x: 10, y: 10, width: 100, height: 40))
        anchor.anchorKey = "a30-old"
        window.addSubview(anchor)

        anchor.anchorKey = "a30-new"

        #expect(!registry.isRegistered("a30-old"))
        #expect(registry.getView(for: "a30-new") === anchor)
        anchor.removeFromSuperview()
    }

    @Test("scrollToVisible brings a UIKit anchor inside a UIScrollView on screen and says so")
    func scrollToVisibleUIKit() {
        let window = makeWindow()
        let scrollView = UIScrollView(frame: window.bounds)
        scrollView.contentSize = CGSize(width: window.bounds.width, height: 4000)
        window.addSubview(scrollView)
        let anchor = DigiaAnchorView(frame: CGRect(x: 10, y: 3000, width: 100, height: 40))
        anchor.anchorKey = "a30-scroll"
        scrollView.addSubview(anchor)
        pump()
        #expect(registry.resolution(for: "a30-scroll") == .unavailable(.outsideViewport))

        // True in the same pass, although the presentation layer hasn't caught up yet.
        #expect(registry.scrollToVisible("a30-scroll"))
        pump()
        #expect(registry.resolution(for: "a30-scroll").isAvailable)
        scrollView.removeFromSuperview()
    }

    @Test("a SwiftUI anchor in a ScrollView is available on screen and unavailable scrolled away")
    func swiftUIAnchorInScrollView() throws {
        let window = makeWindow()
        let host = UIHostingController(rootView: AnchoredScrollContent(key: "a30-swiftui"))
        window.rootViewController = host
        pump()
        #expect(registry.resolution(for: "a30-swiftui") == .unavailable(.outsideViewport))

        let scrollView = try #require(firstScrollView(in: host.view))
        #expect(registry.scrollToVisible("a30-swiftui"))
        pump()
        #expect(registry.resolution(for: "a30-swiftui").isAvailable)

        scrollView.setContentOffset(.zero, animated: false)
        pump()
        #expect(registry.resolution(for: "a30-swiftui") == .unavailable(.outsideViewport))
        window.rootViewController = nil
        pump()
        #expect(!registry.isRegistered("a30-swiftui"))
    }

    @Test("tracking an off-screen anchor scrolls it into view before the step shows")
    func trackingScrollsAnchorIntoView() {
        let window = makeWindow()
        let scrollView = UIScrollView(frame: window.bounds)
        scrollView.contentSize = CGSize(width: window.bounds.width, height: 4000)
        window.addSubview(scrollView)
        let anchor = DigiaAnchorView(frame: CGRect(x: 10, y: 3000, width: 100, height: 40))
        anchor.anchorKey = "a30-track"
        scrollView.addSubview(anchor)
        var available: [String] = []

        registry.track(key: "a30-track", onAvailable: { available.append($0) }, onUnavailable: { _, _ in })
        pump()

        #expect(available == ["a30-track"])
        #expect(scrollView.contentOffset.y > 0)
        registry.stopTracking()
        scrollView.removeFromSuperview()
    }

    @Test("removing the anchor hosting the visible step reports it one turn later")
    func removingActiveAnchorReportsNextTurn() async {
        let window = makeWindow()
        let anchor = DigiaAnchorView(frame: CGRect(x: 10, y: 10, width: 100, height: 40))
        anchor.anchorKey = "a30-removed"
        window.addSubview(anchor)
        var removed: [String] = []
        registry.track(
            key: "a30-removed",
            onAvailable: { _ in },
            onUnavailable: { _, _ in },
            onRemoved: { removed.append($0) }
        )

        anchor.removeFromSuperview()
        #expect(removed.isEmpty)
        await nextTurn()
        #expect(removed == ["a30-removed"])
    }

    @Test("removing one of two on-screen views for the step's key is not a removal")
    func removingOneOfTwoViewsKeepsTheStep() async {
        let window = makeWindow()
        let first = DigiaAnchorView(frame: CGRect(x: 10, y: 10, width: 100, height: 40))
        let second = DigiaAnchorView(frame: CGRect(x: 10, y: 80, width: 100, height: 40))
        first.anchorKey = "a30-two"
        second.anchorKey = "a30-two"
        window.addSubview(first)
        window.addSubview(second)
        var removed: [String] = []
        registry.track(
            key: "a30-two",
            onAvailable: { _ in },
            onUnavailable: { _, _ in },
            onRemoved: { removed.append($0) }
        )

        first.removeFromSuperview()
        await nextTurn()

        #expect(removed.isEmpty)
        registry.stopTracking()
        second.removeFromSuperview()
    }
}

private struct AnchoredScrollContent: View {
    let key: String

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(0..<40, id: \.self) { index in
                    if index == 30 {
                        DigiaAnchor(anchorKey: key) { Text("anchor").frame(width: 300, height: 80) }
                    } else {
                        Text("row \(index)").frame(width: 300, height: 80)
                    }
                }
            }
        }
    }
}

@MainActor
private func makeWindow() -> UIWindow {
    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.isHidden = false
    return window
}

@MainActor
private func pump() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}

/// Lets main-queue work scheduled with `DispatchQueue.main.async` run. A nested
/// run loop can't drain the main queue from inside a main-actor job.
@MainActor
private func nextTurn() async {
    try? await Task.sleep(nanoseconds: 100_000_000)
}

@MainActor
private func firstScrollView(in view: UIView) -> UIScrollView? {
    if let scrollView = view as? UIScrollView { return scrollView }
    for subview in view.subviews {
        if let scrollView = firstScrollView(in: subview) { return scrollView }
    }
    return nil
}

private extension AnchorResolution {
    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}
