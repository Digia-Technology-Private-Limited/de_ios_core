// tags: widget guide campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Every way a guide ends and the exact chain it sends: one Viewed, a Step Viewed per step shown, a Step
/// Clicked per CTA, Completed only from the last step's CTA, and a Step Dismissed when it ends short of that.
/// The cases that need a real touch; the rest run in the package, in
/// `Tests/DigiaEngageTests/CampaignBehaviour/GuideCampaignBehaviourTests.swift`. Real touches through `SdkHarness`,
/// on the anchors of `GuideHostScreen`.
///
/// platform note: the Dart twin is `test/campaign_behaviour/guide_campaign_behaviour_test.dart`. Its system-back case (back
/// pops the host screen) has no iOS counterpart; the anchors-leaving case below covers the same end.
@MainActor
@Suite("Guide campaign behaviour: real touches", .serialized, .tags(.integration, .guide, .analytics))
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

    /// The scrim below the host's anchors, clear of every tooltip.
    private func tapOutside(_ sdk: SdkHarness) async throws {
        let bounds = try #require(sdk.window).bounds
        try await sdk.touch(CGPoint(x: bounds.midX, y: bounds.maxY - 80))
    }

    /// The step indexes of `name` events, in order.
    private func steps(_ events: [WireEvent], _ name: String) -> [Int?] {
        events.filter { $0["event_name"] as? String == name }
            .map { ($0["properties"] as? [String: Any])?["item_index"] as? Int }
    }

    // MARK: - Closed

    @Test("single step CTA: completed, dismissed as completed")
    func singleStepCta() async throws {
        let key = "test_guide_tooltip_single"
        let sdk = try await start("guide_tooltip_single_step")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Quick Search Callout")

        try await sdk.tap(id: "dismiss_btn")  // "Close"
        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Quick Search Callout") }

        expectChain(
            await sdk.sent(key), d,
            names: [
                Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepClicked, Chain.completed, Chain.dismissed,
            ],
            reason: .completed, cepClicks: 0)
    }

    @Test("two-step walkthrough to the end: each step, then completed")
    func walkthroughToTheEnd() async throws {
        let key = "test_guide_tooltip_walkthrough"
        let sdk = try await start("guide_tooltip_walkthrough")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Quick Search")

        try await sdk.tap(id: "cta_next")  // "Next"
        try await show(sdk, "Featured Deals")
        try await sdk.tap(id: "cta_done")  // "Got it"
        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Featured Deals") }

        let events = await sdk.sent(key)
        expectChain(
            events, d,
            names: [
                Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepClicked, Chain.stepViewed,
                Chain.stepClicked, Chain.completed, Chain.dismissed,
            ],
            reason: .completed, cepClicks: 0)
        #expect(steps(events, Chain.stepViewed) == [1, 2])
    }

    @Test("three-step tour with a Back: the revisited step counts again")
    func tourWithBack() async throws {
        let key = "test_guide_spotlight_journey"
        let sdk = try await start("guide_spotlight_journey")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Canvas Search")

        // Next, Back, Next, Next, Finish Tour.
        for (id, next) in [
            ("btn_next", "Daily Deals"), ("btn_back", "Canvas Search"), ("btn_next", "Daily Deals"),
            ("btn_next_2", "Top Categories"),
        ] {
            try await sdk.tap(id: id)
            try await show(sdk, next)
        }
        try await sdk.tap(id: "btn_finish")
        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Top Categories") }

        let events = await sdk.sent(key)
        #expect(steps(events, Chain.stepViewed) == [1, 2, 1, 2, 3])
        expectChain(
            events, d,
            names: [
                Chain.triggered, Chain.viewed,
                Chain.stepViewed, Chain.stepClicked, Chain.stepViewed, Chain.stepClicked,
                Chain.stepViewed, Chain.stepClicked, Chain.stepViewed, Chain.stepClicked,
                Chain.stepViewed, Chain.stepClicked, Chain.completed, Chain.dismissed,
            ],
            reason: .completed, cepClicks: 0)
    }

    @Test("outside tap on a single step: scrim_tap, no step dismissed")
    func outsideTapSingleStep() async throws {
        let key = "test_guide_tooltip_outside_dismiss"
        let sdk = try await start("guide_tooltip_outside_dismiss")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Tap Outside to Dismiss Tooltip")

        try await tapOutside(sdk)
        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Tap Outside to Dismiss Tooltip") }

        // As coded: a single-step guide sends its Step Viewed but never a Step Dismissed — that is for
        // multi-step guides only.
        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.dismissed],
            reason: .scrimTap)
    }

    @Test("outside tap on the last of two steps: step dismissed (A60)")
    func outsideTapLastStep() async throws {
        let key = "test_guide_tooltip_walkthrough"
        let sdk = try await start("guide_tooltip_walkthrough")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Quick Search")
        try await sdk.tap(id: "cta_next")  // "Next"
        try await show(sdk, "Featured Deals")

        try await tapOutside(sdk)
        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Featured Deals") }

        let events = await sdk.sent(key)
        expectChain(
            events, d,
            names: [
                Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepClicked, Chain.stepViewed,
                Chain.stepDismissed, Chain.dismissed,
            ],
            reason: .scrimTap)
        #expect(steps(events, Chain.stepDismissed) == [2])
    }

    // As coded, per ADR-004: a single-step guide's CTA completes it, even one whose only action is a plain
    // dismiss ("Skip Tour").
    @Test("Skip Tour: completed, dismissed as completed, as coded")
    func skipTour() async throws {
        let key = "test_guide_tooltip_skip"
        let sdk = try await start("guide_tooltip_skip_action")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Tooltip Walkthrough (Step 1)")

        try await sdk.tap(id: "skip_btn")  // "Skip Tour"
        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Tooltip Walkthrough (Step 1)") }

        let events = await sdk.sent(key)
        expectChain(
            events, d,
            names: [
                Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepClicked, Chain.completed, Chain.dismissed,
            ],
            reason: .completed, cepClicks: 0)
        let stepClicked = propsOf(events, Chain.stepClicked)
        #expect(stepClicked["item_index"] as? Int == 1)
        #expect(stepClicked["cta_label"] as? String == "Skip Tour")
        #expect(stepClicked["action_type"] as? String == "dismiss")
        #expect(propsOf(events, Chain.completed)["item_total"] as? Int == 1)
        guard case .dismissed(_, let completed) = d.outcome else {
            Issue.record("not dismissed: \(String(describing: d.outcome))")
            return
        }
        #expect(completed)
    }

    // As coded, with the case above.
    @Test("Skip Tour: no Step Dismissed, as coded")
    func skipTourNoStepDismissed() async throws {
        let key = "test_guide_tooltip_skip"
        let sdk = try await start("guide_tooltip_skip_action")
        defer { sdk.tearDown() }
        _ = try sdk.deliverChain(key)
        try await show(sdk, "Tooltip Walkthrough (Step 1)")

        try await sdk.tap(id: "skip_btn")
        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Tooltip Walkthrough (Step 1)") }

        #expect(steps(await sdk.sent(key), Chain.stepDismissed).isEmpty)
    }

    // MARK: - Stays

    @Test("a tap on the tooltip bubble does nothing")
    func tapOnTheBubble() async throws {
        let key = "test_guide_tooltip_outside_dismiss"
        let sdk = try await start("guide_tooltip_outside_dismiss")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Tap Outside to Dismiss Tooltip")

        try await sdk.tap(text: "Tap Outside to Dismiss Tooltip")
        #expect(sdk.isShowing("Tap Outside to Dismiss Tooltip"))

        let events = await sdk.sent(key)
        #expect(names(events) == [Chain.triggered, Chain.viewed, Chain.stepViewed])
        let stepViewed = propsOf(events, Chain.stepViewed)
        #expect(stepViewed["item_index"] as? Int == 1)
        #expect(stepViewed["item_total"] as? Int == 1)
        #expect(d.timeline == ["displayed"], "still showing, still holding the CEP")

        // End it, so nothing outlives the test.
        try await tapOutside(sdk)
        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Tap Outside to Dismiss Tooltip") }
    }

    // MARK: - Dropped

    @Test("guide: over its cap: frequency_capped, and the first chain intact")
    func overItsCap() async throws {
        let key = "test_guide_tooltip_single"
        let campaign = guide("guide_tooltip_single_step").cappedAtOne()
        let sdk = try await SdkHarness.startChain([campaign]) { GuideHostScreen() }
        defer { sdk.tearDown() }
        let first = try sdk.deliverChain(key)
        try await show(sdk, "Quick Search Callout")
        try await sdk.tap(id: "dismiss_btn")  // "Close"
        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Quick Search Callout") }

        let second = try sdk.deliverChain(key)
        try await sdk.settle(1)
        #expect(!sdk.isShowing("Quick Search Callout"))

        let events = await sdk.sent(key)
        expectChain(
            eventsOf(first, in: events), first,
            names: [
                Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepClicked, Chain.completed, Chain.dismissed,
            ],
            reason: .completed, cepClicks: 0)
        expectDroppedWire(
            eventsOf(second, in: events), second, .frequencyCapped, campaign, screen: nil,
            extras: ["cap_rule": "max_total", "cap_limit": 1])
    }
}


