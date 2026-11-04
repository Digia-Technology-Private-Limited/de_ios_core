// tags: widget inline campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Inline content in its slot and the exact chain it sends. The CEP's hold comes back at acceptance, before
/// any impression, and the content sends no Digia Dismissed: when its slot is cleared, only the CEP hears of
/// it. The cases that need a real touch, and the carousel's (it pages only in a running app); the rest run in
/// the package, in
/// `Tests/DigiaEngageTests/CampaignBehaviour/InlineCampaignBehaviourTests.swift`. Real touches through `SdkHarness`.
///
/// platform note: the Dart twin is `test/campaign_behaviour/inline_campaign_behaviour_test.dart`.
@MainActor
@Suite("Inline campaign behaviour: real touches", .serialized, .tags(.integration, .inline, .analytics))
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
        try await sdk.settle(0.5)
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
        try await sdk.settle(0.5)
        try await sdk.tap(id: "canvas_button")
        try await sdk.settle(0.5)

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
        try await sdk.settle(0.5)
        try await sdk.tap(id: "canvas_button")
        try await sdk.settle(0.5)

        let events = await sdk.sent(key)
        expectInlineChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.clicked], cepClicks: 2)
        #expect((events.dropFirst(2).first?["properties"] as? [String: Any])?["cta_role"] as? String == "primary")
    }

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
        try await sdk.settle(1)
        try await sdk.touch(try slotPoint(sdk, dx: window.bounds.midX, dy: 60))
        try await sdk.settle(1)

        // Item taps stay Digia only; only a container tap reaches the CEP.
        expectInlineChain(
            await sdk.sent(key), d,
            names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.clicked, Chain.stepClicked, Chain.stepClicked])
    }

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
            [WorkspaceFixtures.campaign("campaigns/canvas_tap_targets/canvas_overlapping_tap_targets.json")], slot: "home_banner")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        try await sdk.tap(id: id)
        try await sdk.settle(0.5)
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
        try await sdk.settle(0.5)
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

    // MARK: - Carousel timing

    @Test("carousel without autoplay stays on slide 1", .tags(.slow))
    func noAutoplayStays() async throws {
        let key = "test_inline_carousel_infinite"
        let (sdk, d) = try await startCarousel("inline_carousel_infinite_scroll", key: key)
        defer { sdk.tearDown() }

        try await sdk.settle(5)
        #expect(try slideShown(sdk, slides: 2) == 1)

        let events = await sdk.sent(key)
        expectInlineChain(events, d, names: [Chain.triggered, Chain.viewed, Chain.stepViewed])
        #expect(stepsViewed(events) == ["(1, 2, 0)"])
    }

    // As coded: a swipe does not restart the autoplay timer (`startAutoPlay` runs only on appear), so the next
    // advance comes on the timer's first schedule, about 1 s after a swipe at about 1 s, not 2 s after it.
    @Test("carousel autoplay: the next advance after a swipe keeps the timer's schedule, as coded")
    func autoplayAfterASwipe() async throws {
        let key = "test_inline_carousel_autoplay"
        let sdk = try await start([carousel("inline_carousel_autoplay")], slot: "home_featured_carousel")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await sdk.waitUntil("the inline impression", timeout: 5) { d.displayed }
        try await sdk.settle(0.6)

        // A finger flick to slide 2 at about 0.6–0.85 s.
        let scroller = try carouselScroller(sdk)
        let window = try #require(sdk.window)
        let frame = scroller.convert(scroller.bounds, to: window)
        try TouchSynthesizer.drag(
            from: CGPoint(x: frame.midX + 120, y: frame.midY), by: CGVector(dx: -240, dy: 0),
            in: window, duration: 0.25)
        let swipedAt = Date()
        try await waitForSlide(sdk, 2, timeout: 1.5)
        try await waitForSlide(sdk, 1, timeout: 3)
        let advancedAfter = Date().timeIntervalSince(swipedAt)

        #expect(advancedAfter < 1.6, "advanced \(advancedAfter) s after the swipe")
        let events = await sdk.sent(key)
        expectInlineChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.stepViewed, Chain.stepViewed, Chain.stepViewed])
        #expect(stepsViewed(events) == ["(1, 2, 0)", "(2, 2, 0)", "(1, 2, 1)"])
    }

    // MARK: - Story timing and swipes

    private func storyOpen() -> Bool { SDKInstance.shared.controller.activeStoryOverlay != nil }

    // As coded: past its last item the viewer sends Completed and closes; no Step Dismissed, no outcome.
    @Test("story auto advance: each item in turn, then Completed and the viewer closes, as coded", .tags(.slow))
    func storyAutoAdvance() async throws {
        let key = "test_inline_story_auto_advance"
        let sdk = try await start(
            [WorkspaceFixtures.campaign("campaigns/inline_story/inline_story_auto_advance.json")],
            slot: "test_inline_stories")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        try await sdk.touch(try slotPoint(sdk, dx: 40, dy: 40))
        try await sdk.waitUntil("the first item", timeout: 5) { sdk.isShowing("First Offer") }
        // 3 s per item.
        try await sdk.waitUntil("the second item", timeout: 5) { sdk.isShowing("Second Offer") }
        try await sdk.waitUntil("the viewer closes", timeout: 5) { !storyOpen() }
        #expect(SDKInstance.shared.inlineController.getCampaign("test_inline_stories") != nil, "the slot keeps it")

        let events = await sdk.sent(key)
        expectInlineChain(
            events, d,
            names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.stepViewed, Chain.stepViewed, Chain.completed],
            cepClicks: 1)
        #expect(steps(events, Chain.stepViewed) == ["(1, 2)", "(2, 2)"])
        #expect(propsOf(events, Chain.completed)["item_total"] as? Int == 2)
    }

    // As coded: the iOS viewer pages by its tap zones; a horizontal swipe is no gesture of its own (only a
    // swipe down, or right from the left edge, closes it), so it stays on item 1 and sends nothing.
    @Test("story swipe next: a swipe left on the viewer, as coded")
    func storySwipeNext() async throws {
        let key = "test_inline_story_swipe"
        let sdk = try await start(
            [WorkspaceFixtures.campaign("campaigns/inline_story/inline_story_swipe_next.json")],
            slot: "test_inline_stories")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        try await sdk.touch(try slotPoint(sdk, dx: 40, dy: 40))
        try await sdk.waitUntil("the story viewer is open", timeout: 5) { storyOpen() }
        try await sdk.settle(0.5)
        let bounds = try #require(sdk.window).bounds
        try await sdk.swipe(
            from: CGPoint(x: bounds.midX + 120, y: bounds.midY), to: CGPoint(x: bounds.midX - 120, y: bounds.midY))
        #expect(storyOpen(), "the viewer stays open")

        let events = await sdk.sent(key)
        expectInlineChain(events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.stepViewed], cepClicks: 1)
        #expect(steps(events, Chain.stepViewed) == ["(1, 2)"])
    }
}
