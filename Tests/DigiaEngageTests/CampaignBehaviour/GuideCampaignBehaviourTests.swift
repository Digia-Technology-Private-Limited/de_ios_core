// tags: widget guide campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension RenderedUITests {
/// Every way a guide ends and the exact chain it sends: one Viewed, a Step Viewed per step shown, a Step
/// Clicked per CTA, Completed only from the last step's CTA, and a Step Dismissed when it ends short of that.
/// On the anchors of `GuideHostScreen`. The cases that need a real touch run hosted, in
/// `SampleApp/DigiaEngageSampleTests/CampaignBehaviour/GuideCampaignBehaviourTests.swift`.
///
/// platform note: the Dart twin is `test/campaign_behaviour/guide_campaign_behaviour_test.dart`. Its system-back case (back
/// pops the host screen) has no iOS counterpart; the anchors-leaving case below covers the same end.
@MainActor
@Suite("Guide campaign behaviour", .serialized, .tags(.integration, .guide, .analytics))
struct GuideCampaignBehaviourTests {
    private func guide(_ name: String) -> WorkspaceFixtures.Campaign {
        WorkspaceFixtures.campaign(
            "campaigns/\(name.hasPrefix("guide_spotlight") ? "guide_spotlight" : "guide_tooltip")/\(name).json")
    }

    private func start(_ name: String) async throws -> SdkHarness {
        try await SdkHarness.startChain([guide(name)]) { GuideHostScreen() }
    }

    private func show(_ sdk: SdkHarness, _ text: String) async throws {
        try await sdk.waitUntil("\"\(text)\" on screen") { sdk.isShowing(text) }
        try await sdk.settle(0.4)
    }

    /// The step indexes of `name` events, in order.
    private func steps(_ events: [WireEvent], _ name: String) -> [Int?] {
        events.filter { $0["event_name"] as? String == name }
            .map { ($0["properties"] as? [String: Any])?["item_index"] as? Int }
    }

    // MARK: - Closed

    @Test("guide: leaving its screen: dismissed as screen_exit")
    func leavingItsScreen() async throws {
        let key = "test_guide_tooltip_walkthrough"
        let sdk = try await start("guide_tooltip_walkthrough")
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "home")
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Quick Search")

        Digia.setCurrentScreen(name: "search")
        try await sdk.settle()
        #expect(!sdk.isShowing("Quick Search"))

        expectChain(
            await sdk.sent(key), d,
            names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepDismissed, Chain.dismissed],
            reason: .screenExit)
    }

    @Test("its anchor leaving the tree: dismissed as target_lost")
    func anchorLeavingTheTree() async throws {
        let key = "test_guide_tooltip_walkthrough"
        let anchors = AnchorsShown()
        let sdk = try await SdkHarness.startChain([guide("guide_tooltip_walkthrough")]) {
            ToggledGuideHostScreen(anchors: anchors)
        }
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Quick Search")

        anchors.shown = false
        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Quick Search") }

        expectChain(
            await sdk.sent(key), d,
            names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepDismissed, Chain.dismissed],
            reason: .targetLost)
    }

    // MARK: - Dropped

    @Test("no anchor on screen: anchor_not_registered")
    func noAnchorOnScreen() async throws {
        let key = "test_guide_tooltip_single"
        let sdk = try await SdkHarness.startChain([guide("guide_tooltip_single_step")]) { Text("App home") }
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        // The guide waits two seconds for its anchor before giving up.
        try await sdk.settle(3)

        expectDropped(await sdk.sent(key), d, .anchorNotRegistered)
    }

    @Test("guide: a nudge already up: surface_busy")
    func nudgeAlreadyUp() async throws {
        let key = "test_guide_tooltip_single"
        let sdk = try await SdkHarness.startChain([
            WorkspaceFixtures.campaign("campaigns/nudge_dialog/nudge_dialog.json"), guide("guide_tooltip_single_step"),
        ]) { GuideHostScreen() }
        defer { sdk.tearDown() }
        _ = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")

        let d = try sdk.deliverChain(key)
        try await sdk.settle()
        #expect(!sdk.isShowing("Quick Search Callout"))

        expectDropped(await sdk.sent(key), d, .surfaceBusy)
    }

    // As coded: a classic guide (steps with no canvas) is parsed into the store, but this renderer shows canvas
    // steps only, so routing turns it away `invalid_config`, with nothing on screen.
    @Test("a guide with no canvas steps: invalid_config (as coded)")
    func noCanvasSteps() async throws {
        let key = "test_guide_tooltip_classic_stack_push"
        let campaign = guide("guide_tooltip_classic_stack_push")
        let sdk = try await SdkHarness.startChain([campaign]) { GuideHostScreen() }
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "home")  // the fixture targets home
        let d = try sdk.deliverChain(key)
        try await sdk.settle(1)

        expectDroppedWire(
            await sdk.sent(key), d, .invalidConfig, campaign, screen: "home",
            extras: ["cause": "empty_content"], detail: "campaign has no valid Canvas guide content")
    }

    @Test("guide: CEP cancel before it shows: cancelled")
    func cepCancelBeforeShowing() async throws {
        let key = "test_guide_tooltip_single"
        let campaign = guide("guide_tooltip_single_step")
        let sdk = try await SdkHarness.startChain([campaign]) { GuideHostScreen() }
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        d.presentation.cancel()
        try await sdk.settle(1)
        #expect(!sdk.isShowing("Quick Search Callout"))

        expectDroppedWire(
            await sdk.sent(key), d, .cancelled, campaign, screen: nil,
            extras: ["cancel_cause": "cep_cancel"])
    }

    @Test("guide: off its target screen: screen_not_targeted")
    func offItsTargetScreen() async throws {
        let key = "test_guide_tooltip_screen_change_allowed"
        let campaign = guide("guide_tooltip_screen_change_allowed")
        let sdk = try await SdkHarness.startChain([campaign]) { GuideHostScreen() }
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "cart")
        let d = try sdk.deliverChain(key)
        try await sdk.settle(1)

        expectDroppedWire(
            await sdk.sent(key), d, .screenNotTargeted, campaign, screen: "cart",
            extras: ["target_screens": ["home", "search"]],
            detail: "currentScreen=cart targetScreenNames=[\"home\", \"search\"]")
    }
}
}

@MainActor
private final class AnchorsShown: ObservableObject {
    @Published var shown = true
}

/// ``GuideHostScreen`` until the test takes its anchors away.
private struct ToggledGuideHostScreen: View {
    @ObservedObject var anchors: AnchorsShown

    var body: some View {
        if anchors.shown { GuideHostScreen() } else { Color.clear }
    }
}
