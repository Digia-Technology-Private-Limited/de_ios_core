// tags: widget inline campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Inline content in its slot and the exact chain it sends. The CEP's hold comes back at acceptance, before
/// any impression, and the content sends no Digia Dismissed: when its slot is cleared, only the CEP hears of
/// it. Real touches through `SdkHarness`.
///
/// platform note: the Dart twin is `test/campaign_behaviour/inline_campaign_behaviour_test.dart`.
@MainActor
@Suite("Inline campaign behaviour", .serialized, .tags(.integration, .inline, .analytics))
struct InlineCampaignBehaviourTests {
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

    // MARK: - Carousel autoplay and swipes

    // Two-slide canvas carousels with infinite scroll: a Step Viewed per slide reached (`auto` true for autoplay,
    // false for a swipe), never a click, and nothing to the CEP past its impression.

    private func carousel(_ name: String) -> WorkspaceFixtures.Campaign {
        WorkspaceFixtures.campaign("campaigns/inline_carousel/\(name).json")
    }

    /// The carousel's paging scroll view: the widest-content horizontal scroller on screen.
    private func carouselScroller(_ sdk: SdkHarness) throws -> UIScrollView {
        func scrollers(in view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollers)
        }
        let window = try #require(sdk.window)
        return try #require(
            scrollers(in: window).filter { $0.contentSize.width > $0.bounds.width * 1.5 }
                .max { $0.contentSize.width < $1.contentSize.width },
            "no carousel on screen")
    }

    /// The slide the carousel has settled on, 1-based. Its pages are `[last] + slides + [first]`, each a fixed
    /// stride apart, and the settled one is aligned to the leading content inset.
    private func slideShown(_ sdk: SdkHarness, slides: Int) throws -> Int {
        let scroller = try carouselScroller(sdk)
        let stride = scroller.contentSize.width / CGFloat(slides + 2)
        let display = Int(((scroller.contentOffset.x + scroller.adjustedContentInset.left) / stride).rounded())
        return ((display - 1) % slides + slides) % slides + 1
    }

    private func waitForSlide(_ sdk: SdkHarness, _ slide: Int, timeout: TimeInterval = 3.5) async throws {
        try await sdk.waitUntil("slide \(slide) shown", timeout: timeout) { (try? slideShown(sdk, slides: 2)) == slide }
    }

    /// A finger flick across the carousel: `dx` < 0 for the next slide, > 0 for the previous.
    private func swipeCarousel(_ sdk: SdkHarness, dx: CGFloat) async throws {
        let scroller = try carouselScroller(sdk)
        let frame = scroller.convert(scroller.bounds, to: try #require(sdk.window))
        let start = CGPoint(x: frame.midX - dx / 2, y: frame.midY)
        try await sdk.swipe(from: start, to: CGPoint(x: start.x + dx, y: start.y))
    }

    /// Every Step Viewed as (item_index, item_total, auto).
    private func stepsViewed(_ events: [WireEvent]) -> [String] {
        events.filter { $0["event_name"] as? String == Chain.stepViewed }.map {
            let p = $0["properties"] as? [String: Any] ?? [:]
            return "(\(p["item_index"] ?? "nil"), \(p["item_total"] ?? "nil"), \(p["auto"] ?? "nil"))"
        }
    }

    private func startCarousel(_ name: String, key: String) async throws -> (SdkHarness, Delivery) {
        let sdk = try await start([carousel(name)], slot: "home_featured_carousel")
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)
        return (sdk, d)
    }

    // Fails today: the first slide's Digia Step Viewed is sent before Digia Experience Viewed (expected Viewed first, as on Flutter).
    @Test("carousel autoplay advances to slide 2 after its interval")
    func autoplayAdvances() async throws {
        let key = "test_inline_carousel_autoplay"
        let (sdk, d) = try await startCarousel("inline_carousel_autoplay", key: key)
        defer { sdk.tearDown() }
        #expect(try slideShown(sdk, slides: 2) == 1)

        // Every 2 s, animated over 400 ms.
        try await waitForSlide(sdk, 2)

        let events = await sdk.sent(key)
        expectInlineChain(events, d, names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepViewed])
        #expect(stepsViewed(events) == ["(1, 2, 0)", "(2, 2, 1)"])
    }

    // Fails today: the first slide's Digia Step Viewed is sent before Digia Experience Viewed (expected Viewed first, as on Flutter).
    @Test("carousel autoplay wraps from the last slide back to slide 1")
    func autoplayWraps() async throws {
        let key = "test_inline_carousel_autoplay"
        let (sdk, d) = try await startCarousel("inline_carousel_autoplay", key: key)
        defer { sdk.tearDown() }

        try await waitForSlide(sdk, 2)
        try await waitForSlide(sdk, 1)

        let events = await sdk.sent(key)
        expectInlineChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepViewed, Chain.stepViewed])
        #expect(stepsViewed(events) == ["(1, 2, 0)", "(2, 2, 1)", "(1, 2, 1)"])
    }

    // Fails today: the first slide's Digia Step Viewed is sent before Digia Experience Viewed (expected Viewed first, as on Flutter).
    @Test("carousel autoplay sends no Clicked and no Step Clicked")
    func autoplaySendsNoClicks() async throws {
        let key = "test_inline_carousel_autoplay"
        let (sdk, d) = try await startCarousel("inline_carousel_autoplay", key: key)
        defer { sdk.tearDown() }

        // Three advances: 2, 1, 2.
        try await waitForSlide(sdk, 2)
        try await waitForSlide(sdk, 1)
        try await waitForSlide(sdk, 2)

        let events = await sdk.sent(key)
        expectInlineChain(
            events, d,
            names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepViewed, Chain.stepViewed, Chain.stepViewed])
        #expect(stepsViewed(events) == ["(1, 2, 0)", "(2, 2, 1)", "(1, 2, 1)", "(2, 2, 1)"])
    }

    // Fails today: the first slide's Digia Step Viewed is sent before Digia Experience Viewed (expected Viewed first, as on Flutter).
    @Test("carousel: a swipe left goes to slide 2")
    func swipeLeft() async throws {
        let key = "test_inline_carousel_infinite"
        let (sdk, d) = try await startCarousel("inline_carousel_infinite_scroll", key: key)
        defer { sdk.tearDown() }
        #expect(try slideShown(sdk, slides: 2) == 1)

        try await swipeCarousel(sdk, dx: -240)
        #expect(try slideShown(sdk, slides: 2) == 2)

        let events = await sdk.sent(key)
        expectInlineChain(events, d, names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepViewed])
        #expect(stepsViewed(events) == ["(1, 2, 0)", "(2, 2, 0)"])
    }

    // Fails today: the first slide's Digia Step Viewed is sent before Digia Experience Viewed (expected Viewed first, as on Flutter).
    @Test("carousel: swiping past the last slide wraps to slide 1")
    func swipePastTheLast() async throws {
        let key = "test_inline_carousel_infinite"
        let (sdk, d) = try await startCarousel("inline_carousel_infinite_scroll", key: key)
        defer { sdk.tearDown() }

        try await swipeCarousel(sdk, dx: -240)
        try await swipeCarousel(sdk, dx: -240)
        #expect(try slideShown(sdk, slides: 2) == 1)

        let events = await sdk.sent(key)
        expectInlineChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepViewed, Chain.stepViewed])
        #expect(stepsViewed(events) == ["(1, 2, 0)", "(2, 2, 0)", "(1, 2, 0)"])
    }

    // Fails today: the first slide's Digia Step Viewed is sent before Digia Experience Viewed (expected Viewed first, as on Flutter).
    @Test("carousel: a swipe right on the first slide wraps back to the last")
    func swipeRightOnTheFirst() async throws {
        let key = "test_inline_carousel_infinite"
        let (sdk, d) = try await startCarousel("inline_carousel_infinite_scroll", key: key)
        defer { sdk.tearDown() }

        try await swipeCarousel(sdk, dx: 240)
        #expect(try slideShown(sdk, slides: 2) == 2)

        // Swipes are never clicks: no Clicked, no Step Clicked, none to the CEP.
        let events = await sdk.sent(key)
        expectInlineChain(events, d, names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepViewed])
        #expect(stepsViewed(events) == ["(1, 2, 0)", "(2, 2, 0)"])
    }

    // MARK: - Canvas tap targets

    // Three stacked layers in one canvas: which one a tap reaches, read off the URL each layer opens. Every
    // target is a secondary CTA, so the CEP hears no click.

    private func tapLayer(
        _ id: String, opens url: String, elementId: String, ctaLabel: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let key = "test_canvas_overlapping_tap_targets"
        let sdk = try await start(
            [WorkspaceFixtures.campaign("campaigns/canvas/canvas_overlapping_tap_targets.json")], slot: "home_banner")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        try await sdk.tap(id: id)
        await sdk.settle(0.5)
        #expect(sdk.platform.opened == [url], sourceLocation: sourceLocation)

        let events = await sdk.sent(key)
        expectInlineChain(events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked], sourceLocation: sourceLocation)
        let viewed = propsOf(events, Chain.viewed, sourceLocation: sourceLocation)
        #expect(viewed["display_style"] as? String == "canvas", sourceLocation: sourceLocation)
        #expect(viewed["slot_key"] as? String == "home_banner", sourceLocation: sourceLocation)
        let clicked = propsOf(events, Chain.clicked, sourceLocation: sourceLocation)
        #expect(clicked["element_id"] as? String == elementId, sourceLocation: sourceLocation)
        #expect(clicked["cta_role"] as? String == "secondary", sourceLocation: sourceLocation)
        #expect(clicked["action_type"] as? String == "url", sourceLocation: sourceLocation)
        if let ctaLabel { #expect(clicked["cta_label"] as? String == ctaLabel, sourceLocation: sourceLocation) }
    }

    // As coded: a button with no action lets the tap through to the region under it.
    @Test("canvas tap targets: a top button with no action: the region under it, as coded")
    func topButtonWithNoAction() async throws {
        try await tapLayer("case1_button", opens: "https://digia.com/hit/case1-underlay", elementId: "case1_underlay")
    }

    // A button's element_id is its role (`cta_secondary`), not its node id.
    @Test("canvas tap targets: a top button with an action wins over the region under it")
    func topButtonWithAnAction() async throws {
        try await tapLayer(
            "case2_button", opens: "https://digia.com/hit/case2-button", elementId: "cta_secondary",
            ctaLabel: "Top button")
    }

    @Test("canvas tap targets: a top tap region wins over the button under it")
    func topTapRegion() async throws {
        // The button's centre, which the region above it covers.
        try await tapLayer("case3_button", opens: "https://digia.com/hit/case3-underlay", elementId: "case3_region")
    }

    // MARK: - Story viewer close

    // One 30 s image story with a CTA and no authored close button. Flutter closes the viewer with system back;
    // on iOS the user swipes it down (InlineStoryOverlayContent's DragGesture → dismissStoryOverlay()).

    private func startStory() async throws -> (SdkHarness, Delivery) {
        let sdk = try await start(
            [WorkspaceFixtures.campaign("campaigns/inline_story/inline_story_close_button.json")],
            slot: "test_inline_stories")
        let d = try sdk.deliverChain("test_inline_story_close")
        try await show(sdk, d)
        return (sdk, d)
    }

    private func openStory(_ sdk: SdkHarness) async throws {
        try await sdk.touch(try slotPoint(sdk, dx: 40, dy: 40))
        try await sdk.waitUntil("the story viewer is open", timeout: 5) { sdk.isShowing("Dismissable Offer") }
        await sdk.settle(0.5)
    }

    private func swipeStoryDown(_ sdk: SdkHarness) async throws {
        let bounds = try #require(sdk.window).bounds
        try await sdk.swipe(from: CGPoint(x: bounds.midX, y: bounds.midY - 120),
                            to: CGPoint(x: bounds.midX, y: bounds.midY + 220))
        try await sdk.waitUntil("the story viewer is closed", timeout: 3) { !sdk.isShowing("Dismissable Offer") }
    }

    /// Every `name` event as (item_index, item_total).
    private func steps(_ events: [WireEvent], _ name: String) -> [String] {
        events.filter { $0["event_name"] as? String == name }.map {
            let p = $0["properties"] as? [String: Any] ?? [:]
            return "(\(p["item_index"] ?? "nil"), \(p["item_total"] ?? "nil"))"
        }
    }

    private func clickedElements(_ d: Delivery) -> [String?] {
        d.signals.compactMap { if case .clicked(let elementId) = $0 { elementId } else { nil } }
    }

    // Fails today: Viewed carries no item_total, and the CEP's click is element story_thumbnail (expected item_total 1 and story_item_1, as on Flutter).
    @Test("story close: the viewer shows the CTA")
    func storyViewerShowsCta() async throws {
        let key = "test_inline_story_close"
        let (sdk, d) = try await startStory()
        defer { sdk.tearDown() }
        try await openStory(sdk)
        #expect(sdk.isShowing("Dismissable Offer"))

        let events = await sdk.sent(key)
        // As coded: opening reaches the CEP as a click on the story item.
        expectInlineChain(events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.stepViewed], cepClicks: 1)
        let viewed = propsOf(events, Chain.viewed)
        #expect(viewed["display_style"] as? String == "stories")
        #expect(viewed["item_total"] as? Int == 1)
        #expect(viewed["slot_key"] as? String == "test_inline_stories")
        #expect(propsOf(events, Chain.clicked)["element_id"] as? String == "story_open")
        #expect(steps(events, Chain.stepViewed) == ["(1, 1)"])
        #expect(clickedElements(d) == ["story_item_1"])
    }

    // As coded: closing the viewer short of its end sends Step Dismissed for the item on screen; the strip and
    // the slot stay, with no outcome.
    @Test("story close: closing the viewer: Step Dismissed, the strip stays, as coded")
    func storyViewerClosed() async throws {
        let key = "test_inline_story_close"
        let (sdk, d) = try await startStory()
        defer { sdk.tearDown() }
        try await openStory(sdk)

        try await swipeStoryDown(sdk)
        #expect(SDKInstance.shared.inlineController.getCampaign("test_inline_stories") != nil, "the slot keeps it")

        let events = await sdk.sent(key)
        expectInlineChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.stepViewed, Chain.stepDismissed],
            cepClicks: 1)
        #expect(steps(events, Chain.stepDismissed) == ["(1, nil)"])
    }

    // As coded: every opening is a Clicked and a Step Viewed, and a click to the CEP.
    // Fails today: the CEP's clicks are element story_thumbnail (expected story_item_1, as on Flutter).
    @Test("story close: reopening counts again, as coded")
    func storyReopened() async throws {
        let key = "test_inline_story_close"
        let (sdk, d) = try await startStory()
        defer { sdk.tearDown() }
        try await openStory(sdk)
        try await swipeStoryDown(sdk)

        try await openStory(sdk)
        #expect(sdk.isShowing("Dismissable Offer"))

        let events = await sdk.sent(key)
        expectInlineChain(
            events, d,
            names: [
                Chain.triggered, Chain.viewed, Chain.clicked, Chain.stepViewed, Chain.stepDismissed, Chain.clicked,
                Chain.stepViewed,
            ],
            cepClicks: 2)
        #expect(clickedElements(d) == ["story_item_1", "story_item_1"])
    }
}
