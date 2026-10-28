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
        try await sdk.settle()
        #expect(SDKInstance.shared.floaterStoryOrchestrator.state == nil)

        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .screenExit,
            hold: .floating)
    }
}
