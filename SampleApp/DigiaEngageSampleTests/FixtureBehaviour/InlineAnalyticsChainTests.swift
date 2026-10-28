// tags: widget inline analytics
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Inline content in its slot and the exact chain it sends. The CEP's hold comes back at acceptance, before
/// any impression, and the content sends no Digia Dismissed: when its slot is cleared, only the CEP hears of
/// it. Real touches through `SdkHarness`.
///
/// platform note: the Dart twin is `test/analytics_chain/inline_chain_test.dart`.
@MainActor
@Suite("Inline analytics chain", .serialized, .tags(.integration, .inline, .analytics))
struct InlineAnalyticsChainTests {
    private func canvasCta() -> WorkspaceFixtures.Campaign {
        WorkspaceFixtures.campaign("campaigns/inline_canvas/inline_canvas_interactive_cta.json")
    }

    /// `campaign` with every authored button made primary.
    private func withPrimaryButtons(_ campaign: WorkspaceFixtures.Campaign) -> WorkspaceFixtures.Campaign {
        func walk(_ node: any Sendable) -> any Sendable {
            if var map = node as? [String: any Sendable] {
                if map["type"] as? String == "digia/button", var props = map["props"] as? [String: any Sendable] {
                    props["isPrimary"] = true
                    map["props"] = props
                }
                return map.mapValues(walk)
            }
            if let list = node as? [any Sendable] { return list.map(walk) }
            return node
        }
        return WorkspaceFixtures.Campaign(name: campaign.name, json: campaign.json.mapValues(walk))
    }

    /// The app screen with `slotKey`'s slot at its top.
    private func start(_ campaigns: [WorkspaceFixtures.Campaign], slot slotKey: String) async throws -> SdkHarness {
        try await SdkHarness.startChain(campaigns) {
            VStack(spacing: 0) { DigiaSlot(slotKey); Spacer() }
        }
    }

    private func show(_ sdk: SdkHarness, _ d: Delivery) async throws {
        try await sdk.waitUntil("the inline impression", timeout: 5) { d.displayed }
        await sdk.settle(0.5)
    }

    /// A point `dy` below the top of the slot, `dx` from its leading edge: the slot sits at the top of the
    /// safe area.
    private func slotPoint(_ sdk: SdkHarness, dx: CGFloat, dy: CGFloat) throws -> CGPoint {
        let window = try #require(sdk.window)
        return CGPoint(x: dx, y: window.safeAreaInsets.top + dy)
    }

    @Test("canvas: secondary CTA: a Digia click per tap, none to the CEP")
    func secondaryCta() async throws {
        let key = "test_inline_canvas_cta"
        let sdk = try await start([canvasCta()], slot: "home_banner")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        try await sdk.tap(id: "canvas_button")  // "Explore Deals"
        await sdk.settle(0.5)
        try await sdk.tap(id: "canvas_button")
        await sdk.settle(0.5)

        let events = await sdk.sent(key)
        expectInlineChain(events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.clicked])
        #expect((events.dropFirst().first?["properties"] as? [String: Any])?["slot_key"] as? String == "home_banner")
    }

    @Test("canvas: primary CTA: every tap also reaches the CEP, as coded")
    func primaryCta() async throws {
        let key = "test_inline_canvas_cta"
        let sdk = try await start([withPrimaryButtons(canvasCta())], slot: "home_banner")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        try await sdk.tap(id: "canvas_button")
        await sdk.settle(0.5)
        try await sdk.tap(id: "canvas_button")
        await sdk.settle(0.5)

        let events = await sdk.sent(key)
        expectInlineChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.clicked], cepClicks: 2)
        #expect((events.dropFirst(2).first?["properties"] as? [String: Any])?["cta_role"] as? String == "primary")
    }

    // Fails today: the CEP hears dismissed(user_close) for a slot the host cleared (clearInlineContent -> dismissCampaign); Flutter reports cancelled.
    @Test("canvas: the host clears its slot: the CEP hears cancelled, Digia none")
    func hostClearsItsSlot() async throws {
        let key = "test_inline_canvas_cta"
        let sdk = try await start([canvasCta()], slot: "home_banner")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        Digia.clearInlineContent("home_banner")
        try await sdk.waitUntil("the slot is empty") { !sdk.isShowing("Special Wellness Program") }

        expectInlineChain(await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed], endedAs: .cancelled)
    }

    @Test("canvas: a second campaign for a shown slot: surface_busy")
    func secondCampaignForShownSlot() async throws {
        var json = canvasCta().json
        json["campaignKey"] = "test_inline_canvas_second"
        json["id"] = "mock-inline-canvas-second"
        let second = WorkspaceFixtures.Campaign(name: "inline_canvas_second", json: json)
        let sdk = try await start([canvasCta(), second], slot: "home_banner")
        defer { sdk.tearDown() }
        let incumbent = try sdk.deliverChain("test_inline_canvas_cta")
        try await show(sdk, incumbent)

        let blocked = try sdk.deliverChain("test_inline_canvas_second")
        await sdk.settle(1)

        let events = await sdk.sent("test_inline_canvas_second")
        expectDropped(events, blocked, .surfaceBusy)
        #expect(propsOf(events, Chain.dropped)["blocking_campaign_key"] as? String == "test_inline_canvas_cta")
        expectInlineChain(await sdk.sent("test_inline_canvas_cta"), incumbent, names: [Chain.triggered, Chain.viewed])
    }

    // Fails today: the first slide's Digia Step Viewed is sent before Digia Experience Viewed (the carousel's step gate reports on exposure before the slot's first-render task sends the impression); Flutter sends Viewed first.
    @Test("carousel: one Clicked on the first item tap, a step per tap")
    func carouselItemTaps() async throws {
        let key = "test_inline_carousel"
        let sdk = try await start(
            [WorkspaceFixtures.campaign("campaigns/inline_carousel/inline_carousel_home.json")],
            slot: "home_featured_carousel")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        // The current slide, in the middle of the slot.
        let window = try #require(sdk.window)
        try await sdk.touch(try slotPoint(sdk, dx: window.bounds.midX, dy: 60))
        await sdk.settle(1)
        try await sdk.touch(try slotPoint(sdk, dx: window.bounds.midX, dy: 60))
        await sdk.settle(1)

        // Item taps stay Digia only; only a container tap reaches the CEP.
        expectInlineChain(
            await sdk.sent(key), d,
            names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.clicked, Chain.stepClicked, Chain.stepClicked])
    }

    // Fails today: opening a story sends its first page's Digia Step Viewed before the opening Digia Experience Clicked; Flutter sends the Clicked first.
    @Test("story: opening it is the Clicked, Digia only")
    func storyOpen() async throws {
        let key = "test_inline_story"
        let sdk = try await start(
            [WorkspaceFixtures.campaign("campaigns/inline_story/inline_story_home.json")], slot: "test_inline_stories")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        // The first card of the rail.
        try await sdk.touch(try slotPoint(sdk, dx: 40, dy: 40))
        try await sdk.waitUntil("the story viewer is open", timeout: 5) { sdk.isShowing("Shop Now") }

        let events = await sdk.sent(key)
        expectInlineChain(events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.stepViewed])
        #expect(propsOf(events, Chain.clicked)["element_id"] as? String == "story_open")
    }
}
