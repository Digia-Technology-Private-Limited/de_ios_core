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

    @Test("a step with a delay scrolls its off-screen anchor only after the delay (A41)")
    func trackingScrollsOnlyAfterStepDelay() {
        let window = makeWindow()
        let scrollView = UIScrollView(frame: window.bounds)
        scrollView.contentSize = CGSize(width: window.bounds.width, height: 4000)
        window.addSubview(scrollView)
        let anchor = DigiaAnchorView(frame: CGRect(x: 10, y: 3000, width: 100, height: 40))
        anchor.anchorKey = "a41-delay"
        scrollView.addSubview(anchor)
        var available: [String] = []
        let restingOffset = scrollView.contentOffset.y

        registry.track(
            key: "a41-delay",
            delayMs: 60,
            onAvailable: { available.append($0) },
            onUnavailable: { _, _ in }
        )
        pump(0.03)
        #expect(scrollView.contentOffset.y == restingOffset)
        #expect(available.isEmpty)
        #expect((registry.remainingStepDelayMs(for: "a41-delay") ?? 0) > 0)

        pump(0.08)
        #expect(scrollView.contentOffset.y > 0)
        #expect(available == ["a41-delay"])
        #expect(registry.remainingStepDelayMs(for: "a41-delay") == 0)
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

    @Test("anchor leaves while its step shows: Digia step event, then user_close to both (A40)")
    func removedAnchorWhileStepShowsMatchesFlutter() async throws {
        let (sdk, window) = try await makeGuideInstance(stepCount: 2)
        let recorder = PresentationRecorder(sdk.triggerCampaign("a40-guide", variables: nil))
        let anchor = try #require(window.subviews.first as? DigiaAnchorView)
        sdk.reportGuideShown()

        anchor.removeFromSuperview()
        await nextTurn()

        #expect(sdk.guideOrchestrator.state == nil)
        #expect(recorder.outcome == .dismissed(reason: .userClose, completed: false))
        #expect(try digiaEventNames(sdk) == [
            "Digia Experience Viewed", "Digia Step Viewed",
            "Digia Step Dismissed", "Digia Experience Dismissed",
        ])
    }

    @Test("anchor of a multi-step guide's last step leaves: Digia completion, still user_close (A40)")
    func removedAnchorOnLastStepCompletesForDigia() async throws {
        let (sdk, window) = try await makeGuideInstance(stepCount: 2)
        let recorder = PresentationRecorder(sdk.triggerCampaign("a40-guide", variables: nil))
        sdk.reportGuideShown()
        sdk.advanceGuide()
        sdk.reportGuideShown()
        let anchor = try #require(window.subviews.last as? DigiaAnchorView)

        anchor.removeFromSuperview()
        await nextTurn()

        #expect(recorder.outcome == .dismissed(reason: .userClose, completed: false))
        let names = try digiaEventNames(sdk)
        #expect(names.suffix(2) == ["Digia Experience Completed", "Digia Experience Dismissed"])
        #expect(!names.contains("Digia Step Dismissed"))
    }

    @Test("anchor leaves before the step shows: user_close to the CEP only, nothing to Digia (A40)")
    func removedAnchorBeforeStepShowsTellsCepOnly() async throws {
        let (sdk, window) = try await makeGuideInstance(stepCount: 1, delayInMs: 5_000)
        let recorder = PresentationRecorder(sdk.triggerCampaign("a40-guide", variables: nil))
        let anchor = try #require(window.subviews.first as? DigiaAnchorView)

        anchor.removeFromSuperview()
        await nextTurn()

        #expect(sdk.guideOrchestrator.state == nil)
        // The CEP is told dismissed(userClose); the coordinator settles a
        // presentation that never displayed as a cancelled drop.
        #expect(!recorder.displayed)
        #expect(recorder.dropReason == .cancelled)
        #expect(recorder.outcome == .dropped(reason: .cancelled, detail: "ended before it displayed (user_close)"))
        #expect(try digiaEventNames(sdk).isEmpty)
    }
}

/// An initialized instance of its own (so Digia events can be read from its
/// queue) with an N-step guide `a40-guide` on screen "Help", and a window
/// holding one on-screen `DigiaAnchorView` per step (`a40-1`, `a40-2`, ...).
@MainActor
private func makeGuideInstance(
    stepCount: Int,
    delayInMs: Int? = nil
) async throws -> (SDKInstance, UIWindow) {
    AnchorRegistry.shared.resetForTesting()
    let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
    let sdk = SDKInstance(
        defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() }
    )
    try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
    let steps: [[String: Any]] = (1...stepCount).map { index in
        var step: [String: Any] = [
            "stepId": "step-\(index)",
            "anchorKey": "a40-\(index)",
            "layoutMode": "canvas",
            "canvas": [
                "version": 2,
                "canvasWidth": 240,
                "canvasHeight": 120,
                "background": ["type": "solid", "color": ["value": "#FFFFFFFF"]],
                "children": [],
            ] as [String: Any],
        ]
        if let delayInMs { step["delayInMs"] = delayInMs }
        return step
    }
    let campaign = try #require(CampaignModel.fromJson([
        "id": "a40-guide-id",
        "campaignKey": "a40-guide",
        "campaignType": "guide",
        "targetScreenNames": ["names": ["Help"]],
        "templateConfig": ["templateType": "tooltip", "steps": steps] as [String: Any],
    ]))
    sdk.setCampaignsForTesting([campaign])
    sdk.setCurrentScreen("Help")
    let window = makeWindow()
    for index in 1...stepCount {
        let anchor = DigiaAnchorView(frame: CGRect(x: 10, y: 60 * index, width: 100, height: 40))
        anchor.anchorKey = "a40-\(index)"
        window.addSubview(anchor)
    }
    return (sdk, window)
}

@MainActor
private func digiaEventNames(_ sdk: SDKInstance) throws -> [String] {
    let analytics = try #require(sdk.services?.analyticsService)
    return analytics.queue.peek(maxCount: 100).compactMap { $0.payload["event_name"] as? String }
        .filter { $0.hasPrefix("Digia ") }
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
private func pump(_ seconds: TimeInterval = 0.1) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
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
