// tags: widget floater pip campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Every way a PiP or story floater ends and the exact chain it sends. Both float over the app, so the CEP's
/// hold comes back at the impression while they keep running. Real touches through `SdkHarness`.
///
/// The chrome's glyph buttons carry no accessibility label, so a test tells them apart by the fixed corner
/// each sits in; the touch on them is still a real one.
///
/// platform note: the Dart twin is `test/campaign_behaviour/floating_campaign_behaviour_test.dart`.
@MainActor
@Suite("Floater campaign behaviour", .serialized, .tags(.integration, .floater, .pip, .analytics))
struct FloaterCampaignBehaviourTests {
    private func fixture(_ path: String) -> WorkspaceFixtures.Campaign { WorkspaceFixtures.campaign(path) }

    private func start(_ path: String) async throws -> SdkHarness {
        try await SdkHarness.startChain([fixture(path)]) { Text("App home") }
    }

    /// Waits for the floater's impression: a PiP shows only once its media has loaded.
    private func show(_ sdk: SdkHarness, _ d: Delivery) async throws {
        try await sdk.waitUntil("the floater's impression", timeout: 5) { d.displayed }
        try await sdk.settle(1)
    }

    /// A real touch on the button nearest `corner` of the area the floater's buttons span.
    private func pressButton(_ sdk: SdkHarness, _ corner: UnitPoint) async throws {
        let window = try #require(sdk.window)
        let frames = UIProbe.buttonFrames(in: window)
        try #require(!frames.isEmpty, "no buttons on screen")
        let bounds = frames.reduce(frames[0]) { $0.union($1) }
        let target = CGPoint(x: bounds.minX + corner.x * bounds.width, y: bounds.minY + corner.y * bounds.height)
        let frame = try #require(
            frames.min {
                hypot($0.midX - target.x, $0.midY - target.y) < hypot($1.midX - target.x, $1.midY - target.y)
            })
        try await sdk.touch(window.convert(CGPoint(x: frame.midX, y: frame.midY), from: window.screen.coordinateSpace))
        try await sdk.settle(1)
    }

    // MARK: - PiP

    @Test("pip: close button: dismissed as user_close")
    func pipCloseButton() async throws {
        let key = "test_pip_close_dismiss"
        let sdk = try await start("campaigns/pip/pip_close_dismiss.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)
        #expect(d.signals.filter { $0 == .displayed }.count == 1)

        try await pressButton(sdk, .topTrailing)

        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .userClose,
            hold: .floating)
    }

    @Test("pip: auto-dismiss: dismissed as auto_timeout", .tags(.slow))
    func pipAutoDismiss() async throws {
        let key = "test_pip_auto_dismiss"
        let sdk = try await start("campaigns/pip/pip_auto_dismiss.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        // The fixture's autoDismissAfterMs is 3000.
        try await sdk.waitUntil("the PiP has timed out", timeout: 5) {
            SDKInstance.shared.floaterOrchestrator.state == nil
        }

        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .autoTimeout,
            hold: .floating)
    }

    @Test("pip: expand, collapse, close: one step, completed at the end")
    func pipExpandCollapseClose() async throws {
        let key = "test_pip_close_dismiss"
        let sdk = try await start("campaigns/pip/pip_close_dismiss.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        try await pressButton(sdk, .bottomLeading)  // expand
        try await pressButton(sdk, .topLeading)  // collapse
        try await pressButton(sdk, .topTrailing)  // close

        expectChain(
            await sdk.sent(key), d,
            names: [
                Chain.triggered, Chain.viewed, Chain.clicked, Chain.stepViewed, Chain.clicked, Chain.stepDismissed,
                Chain.completed, Chain.dismissed,
            ],
            reason: .userClose,
            // PiP chrome is Digia only.
            cepClicks: 0, hold: .floating)
    }

    @Test("pip: full screen CTA authored dismiss: dismissed as cta_action")
    func pipFullScreenCtaDismiss() async throws {
        let key = "test_action_hide_pip"
        let sdk = try await start("actions/action_hide_pip.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)
        try await sdk.waitUntil("the expanded canvas") { sdk.isShowing("Limited Time Health Drop") }

        try await sdk.tap(id: "pip_cta_button")  // "No Thanks"
        try await sdk.waitUntil("the PiP is gone") { SDKInstance.shared.floaterOrchestrator.state == nil }

        expectChain(
            await sdk.sent(key), d,
            names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepClicked, Chain.completed, Chain.dismissed],
            reason: .ctaAction, cepClicks: 0, hold: .floating, wireReason: "cta_taken")
    }

    @Test("pip: leaving its screen: dismissed as screen_exit")
    func pipLeavingItsScreen() async throws {
        let key = "test_pip_screen_change_home_only"
        let sdk = try await start("campaigns/pip/pip_screen_change_home_only.json")
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "home")
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        Digia.setCurrentScreen(name: "search")
        try await sdk.settle()

        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .screenExit,
            hold: .floating)
    }

    @Test("pip: off its target screen: screen_not_targeted")
    func pipOffTargetScreen() async throws {
        let key = "test_pip_screen_change_home_only"
        let sdk = try await start("campaigns/pip/pip_screen_change_home_only.json")
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "search")
        let d = try sdk.deliverChain(key)
        try await sdk.settle(1.5)

        expectDropped(await sdk.sent(key), d, .screenNotTargeted)
    }

    // MARK: - Story floater

    @Test("story floater: close button: dismissed as user_close")
    func storyCloseButton() async throws {
        let key = "test_floater_close"
        let sdk = try await start("campaigns/floater/floater_close_button.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)
        #expect(SDKInstance.shared.floaterStoryOrchestrator.state != nil)

        try await pressButton(sdk, .topTrailing)
        #expect(SDKInstance.shared.floaterStoryOrchestrator.state == nil)

        // As coded: unlike the PiP's and the nudge's, the floater's close button is a Digia click
        // (`floater_close`, secondary) — Digia only.
        let events = await sdk.sent(key)
        expectChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.dismissed], reason: .userClose,
            cepClicks: 0, hold: .floating)
        #expect(propsOf(events, Chain.clicked)["element_id"] as? String == "floater_close")
    }

    @Test("story floater: auto-dismiss: dismissed as auto_timeout", .tags(.slow))
    func storyAutoDismiss() async throws {
        let key = "test_floater_auto_dismiss"
        let sdk = try await start("campaigns/floater/floater_auto_dismiss.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        // The fixture's autoDismissAfterMs is 3000.
        try await sdk.waitUntil("the floater has timed out", timeout: 5) {
            SDKInstance.shared.floaterStoryOrchestrator.state == nil
        }

        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .autoTimeout,
            hold: .floating)
    }

    @Test("story floater: open the story, CTA authored dismiss: cta_action")
    func storyCtaAuthoredDismiss() async throws {
        let key = "test_action_hide_floater_story"
        let sdk = try await start("actions/action_hide_floater_story.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        try FloaterTap.tapWindow(in: try #require(sdk.window))
        try await sdk.waitUntil("the story is open") { sdk.isShowing("Weekend Health Drop") }
        // The story grows out of its window; let the expand finish before it takes touches.
        try await sdk.settle(1.5)
        try await sdk.tap(id: "story_hide_button")  // "No Thanks"
        try await sdk.waitUntil("the story is gone") { !sdk.isShowing("Weekend Health Drop") }

        expectChain(
            await sdk.sent(key), d,
            names: [
                Chain.triggered, Chain.viewed, Chain.clicked, Chain.stepViewed, Chain.stepClicked, Chain.dismissed,
            ],
            // The floater's own name for a CTA ending; the CEP gets cta_action.
            reason: .ctaAction, cepClicks: 0, hold: .floating, wireReason: "cta_taken")
    }

    @Test("story floater: leaving its screen: dismissed as screen_exit")
    func storyLeavingItsScreen() async throws {
        let key = "test_floater_story_screen_change_home_only"
        let sdk = try await start("campaigns/floater/floater_story_screen_change_home_only.json")
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "home")
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        Digia.setCurrentScreen(name: "search")
        // The window fades out before its state clears; wait for that rather than a fixed delay
        // the same length as the fade.
        try await sdk.waitUntil("the story floater is gone") {
            SDKInstance.shared.floaterStoryOrchestrator.state == nil
        }

        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .screenExit,
            hold: .floating)
    }

    // MARK: - Dropped

    @Test("D11 pip: over its cap: frequency_capped, and the first chain intact")
    func pipOverItsCap() async throws {
        let key = "test_pip_close_dismiss"
        let campaign = fixture("campaigns/pip/pip_close_dismiss.json").cappedAtOne()
        let sdk = try await SdkHarness.startChain([campaign]) { Text("App home") }
        defer { sdk.tearDown() }
        let first = try sdk.deliverChain(key)
        try await show(sdk, first)
        try await pressButton(sdk, .topTrailing)

        let second = try sdk.deliverChain(key)
        try await sdk.settle(1.5)
        #expect(SDKInstance.shared.floaterOrchestrator.state == nil)

        let events = await sdk.sent(key)
        expectChain(
            eventsOf(first, in: events), first, names: [Chain.triggered, Chain.viewed, Chain.dismissed],
            reason: .userClose, hold: .floating)
        expectDroppedWire(
            eventsOf(second, in: events), second, .frequencyCapped, campaign, screen: nil,
            extras: ["cap_rule": "max_total", "cap_limit": 1])
    }

    @Test("D11 story floater: over its cap: frequency_capped, and the first chain intact")
    func storyOverItsCap() async throws {
        let key = "test_floater_close"
        let campaign = fixture("campaigns/floater/floater_close_button.json").cappedAtOne()
        let sdk = try await SdkHarness.startChain([campaign]) { Text("App home") }
        defer { sdk.tearDown() }
        let first = try sdk.deliverChain(key)
        try await show(sdk, first)
        try await pressButton(sdk, .topTrailing)

        let second = try sdk.deliverChain(key)
        try await sdk.settle(1.5)
        #expect(SDKInstance.shared.floaterStoryOrchestrator.state == nil)

        let events = await sdk.sent(key)
        expectChain(
            eventsOf(first, in: events), first,
            names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.dismissed], reason: .userClose, cepClicks: 0,
            hold: .floating)
        expectDroppedWire(
            eventsOf(second, in: events), second, .frequencyCapped, campaign, screen: nil,
            extras: ["cap_rule": "max_total", "cap_limit": 1])
    }

    @Test("D12 pip: CEP cancel before it shows: cancelled")
    func pipCepCancelBeforeShowing() async throws {
        let key = "test_pip_close_dismiss"
        let campaign = fixture("campaigns/pip/pip_close_dismiss.json")
        let sdk = try await SdkHarness.startChain([campaign]) { Text("App home") }
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        d.presentation.cancel()
        try await sdk.settle(2)
        #expect(SDKInstance.shared.floaterOrchestrator.state == nil)
        #expect(!d.displayed)

        expectDroppedWire(
            await sdk.sent(key), d, .cancelled, campaign, screen: nil,
            extras: ["cancel_cause": "cep_cancel"], detail: "ended before it displayed (cancelled)")
    }

    @Test("D13 story floater: off its target screen: screen_not_targeted")
    func storyOffTargetScreen() async throws {
        let key = "test_floater_story_screen_change_home_only"
        let campaign = fixture("campaigns/floater/floater_story_screen_change_home_only.json")
        let sdk = try await SdkHarness.startChain([campaign]) { Text("App home") }
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "search")
        let d = try sdk.deliverChain(key)
        try await sdk.settle(1.5)

        expectDroppedWire(
            await sdk.sent(key), d, .screenNotTargeted, campaign, screen: "search",
            extras: ["target_screens": ["home"]], detail: "currentScreen=search targetScreenNames=[\"home\"]")
    }

    // As coded: the image answers 404, so the PiP has no media to float; its window never opens, and the media
    // end it reports reaches the CEP as a cancel (`cancelled`), with the media end as the cause.
    @Test("D14 pip: its image fails to load: dropped as cancelled, as coded")
    func pipMediaFailsToLoad() async throws {
        let key = "test_pip_close_dismiss"
        let base = fixture("campaigns/pip/pip_close_dismiss.json")
        var json = base.json
        var template = try #require(json["templateConfig"] as? [String: any Sendable])
        var media = try #require(template["media"] as? [String: any Sendable])
        media["url"] = "https://images.example.test/missing.jpg"
        template["media"] = media
        json["templateConfig"] = template
        let campaign = WorkspaceFixtures.Campaign(name: base.name, json: json)
        let sdk = try await SdkHarness.startChain(
            [campaign], backend: StubBackend.Options(foreignImagesAsStandIn: false)
        ) { Text("App home") }
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await sdk.waitUntil("the PiP gives up", timeout: 15) { d.outcome != nil }
        #expect(SDKInstance.shared.floaterOrchestrator.state == nil)
        #expect(!d.displayed)

        expectDroppedWire(
            await sdk.sent(key), d, .cancelled, campaign, screen: nil, extras: ["cancel_cause": "auto_timeout"],
            detail: "ended before it displayed (auto_timeout)")
    }

    // MARK: - PiP: moved, and starting expanded

    /// Asserts a floater still running: the exact chain so far and its one impression id, the CEP's hold back
    /// at the impression, and no outcome.
    private func expectStillRunning(
        _ events: [WireEvent], _ d: Delivery, names expected: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(names(events) == expected, sourceLocation: sourceLocation)
        #expect(impressionIds(events) == [d.presentation.id], sourceLocation: sourceLocation)
        #expect(d.timeline == ["displayed", "hold early"], "CEP markings and hold, in order", sourceLocation: sourceLocation)
        #expect(d.outcome == nil, sourceLocation: sourceLocation)
    }

    @Test("pip: dragged to another corner, then closed: moves 1 and the new last_position")
    func pipMovedThenClosed() async throws {
        let key = "test_pip_close_dismiss"
        let sdk = try await start("campaigns/pip/pip_close_dismiss.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)
        let rect = try sdk.pipRect()

        // Past the middle and released at rest: it snaps to the bottom-left corner.
        try FloaterBehaviourDrag.drag(
            from: CGPoint(x: rect.midX, y: rect.midY), by: CGVector(dx: -250, dy: 0),
            in: try #require(sdk.window), duration: 0.5, hold: 0.3)
        try await sdk.waitUntil("the drop is recorded", timeout: 6) { sdk.pip.dragFraction != nil }
        #expect(sdk.pip.dragFraction == FloaterFraction(x: 0, y: 1))
        try await sdk.waitUntilSteady("the PiP settled") { sdk.pip.activeRect }

        try sdk.tapFloater(at: try sdk.pipCloseButton())
        try await sdk.waitUntil("the PiP is gone", timeout: 6) { sdk.pip.state == nil }

        let events = await sdk.sent(key)
        expectChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .userClose, hold: .floating)
        let dismissed = propsOf(events, Chain.dismissed)
        #expect(dismissed["moves"] as? Int == 1)
        #expect(dismissed["last_position"] as? String == "bottom_left")
        #expect(dismissed["expands"] as? Int == 0)
    }

    // The fixture authors no `expanded.onBack`: it collapses by default. As coded, the swipe is reported as a
    // click on the full-screen × (`pip_close`, action `collapse`), the control it stands in for.
    @Test("pip: starts expanded; a swipe down on its top strip (iOS's back) collapses it, as coded")
    func pipInitialExpandedSwipeDown() async throws {
        let key = "test_pip_initial_expanded"
        let sdk = try await start("campaigns/pip/pip_initial_expanded.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)
        #expect(sdk.pip.surface == .expanded)

        try sdk.swipeDownExpandedPip()
        try await sdk.waitUntil("full screen collapses", timeout: 6) { sdk.pip.surface == .collapsed }
        #expect(sdk.pip.isShowing)

        let events = await sdk.sent(key)
        expectStillRunning(
            events, d,
            names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.clicked, Chain.stepDismissed])
        expectCollapseClick(events)
    }

    /// The one Clicked: the full-screen ×, collapsing it (the fixture's default `expanded.onClose`), Digia only.
    private func expectCollapseClick(_ events: [WireEvent], sourceLocation: SourceLocation = #_sourceLocation) {
        let clicked = propsOf(events, Chain.clicked, sourceLocation: sourceLocation)
        #expect(clicked["element_id"] as? String == "pip_close", sourceLocation: sourceLocation)
        #expect(clicked["action_type"] as? String == "collapse", sourceLocation: sourceLocation)
        #expect(clicked["pip_state"] as? String == "expanded", sourceLocation: sourceLocation)
        #expect(clicked["cta_role"] as? String == "secondary", sourceLocation: sourceLocation)
    }

    // As P3: collapsing is a Digia click (here the ×, `pip_close`), and a showing that was full screen ends
    // Completed.
    @Test("pip: starts expanded, collapsed, then closed: expands 0")
    func pipInitialExpandedCollapseThenClose() async throws {
        let key = "test_pip_initial_expanded"
        let sdk = try await start("campaigns/pip/pip_initial_expanded.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)
        #expect(sdk.pip.surface == .expanded)

        // The ×, which collapses by default.
        try sdk.tapFloater(at: try #require(sdk.expandedPipTopRow().last))
        try await sdk.waitUntil("full screen collapses", timeout: 6) { sdk.pip.surface == .collapsed }
        try await sdk.waitUntilSteady("the PiP settled") { sdk.pip.activeRect }
        expectStillRunning(
            await sdk.sent(key), d,
            names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.clicked, Chain.stepDismissed])

        try sdk.tapFloater(at: try sdk.pipCloseButton())
        try await sdk.waitUntil("the PiP is gone", timeout: 6) { sdk.pip.state == nil }

        let events = await sdk.sent(key)
        expectChain(
            events, d,
            names: [
                Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.clicked, Chain.stepDismissed, Chain.completed,
                Chain.dismissed,
            ],
            reason: .userClose, cepClicks: 0, hold: .floating)
        expectCollapseClick(events)
        let dismissed = propsOf(events, Chain.dismissed)
        #expect(dismissed["expands"] as? Int == 0)
        #expect(dismissed["moves"] as? Int == 0)
        #expect(dismissed["last_position"] as? String == "bottom_right")
    }

    // MARK: - Story floater: starting expanded, and running to its end

    @Test("story floater: starts expanded: its story page is drawn without a tap")
    func storyInitialExpanded() async throws {
        let key = "test_floater_story_initial_expanded"
        let sdk = try await start("campaigns/floater/floater_story_initial_expanded.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await sdk.waitUntil("the floater's impression", timeout: 5) { d.displayed }
        let window = try #require(sdk.window)

        try await sdk.waitUntil("the story page is drawn", timeout: 5) {
            let texts = UIProbe.texts(in: window)
            return texts.contains("Weekend Health Drop") && texts.contains("No Thanks")
        }
        let opened = await sdk.sent(key)
        expectStillRunning(opened, d, names: [Chain.triggered, Chain.viewed, Chain.stepViewed])
        let step = propsOf(opened, Chain.stepViewed)
        #expect(step["item_index"] as? Int == 1)
        #expect(step["item_total"] as? Int == 1)

        try await sdk.tap(id: "story_hide_button")  // "No Thanks"
        try await sdk.waitUntil("the story floater is gone") { SDKInstance.shared.floaterStoryOrchestrator.state == nil }

        let events = await sdk.sent(key)
        expectChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepClicked, Chain.dismissed],
            reason: .ctaAction, cepClicks: 0, hold: .floating, wireReason: "cta_taken")
        #expect(propsOf(events, Chain.dismissed)["expands"] as? Int == 0)
    }

    // As coded: `closeStory` ends an `onStoryEnd: dismiss` showing as `cta_taken` (`cta_action` to the CEP).
    @Test("story floater: three pages run out, then it ends per onStoryEnd: dismiss, as coded", .tags(.slow))
    func storyRunsToItsEnd() async throws {
        let key = "test_floater_story_gradient_window_multipage"
        let sdk = try await start("campaigns/floater/floater_story_gradient_window_multipage.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        try FloaterTap.tapWindow(in: try #require(sdk.window))
        try await sdk.waitUntil("the story is open") { sdk.isShowing("Page 1 of 3 (2s)") }
        // Pages of 2 s, 8 s and the default 5 s.
        try await sdk.waitUntil("the story floater is gone", timeout: 20) {
            SDKInstance.shared.floaterStoryOrchestrator.state == nil
        }

        let events = await sdk.sent(key)
        expectChain(
            events, d,
            names: [
                Chain.triggered, Chain.viewed, Chain.clicked, Chain.stepViewed, Chain.stepViewed, Chain.stepViewed,
                Chain.completed, Chain.dismissed,
            ],
            reason: .ctaAction, cepClicks: 0, hold: .floating, wireReason: "cta_taken")
        let pages = events.filter { $0["event_name"] as? String == Chain.stepViewed }
            .map { $0["properties"] as? [String: Any] ?? [:] }
        #expect(pages.map { $0["item_index"] as? Int } == [1, 2, 3])
        #expect(pages.map { $0["item_total"] as? Int } == [3, 3, 3])
        #expect(propsOf(events, Chain.dismissed)["expands"] as? Int == 1)
    }
}
