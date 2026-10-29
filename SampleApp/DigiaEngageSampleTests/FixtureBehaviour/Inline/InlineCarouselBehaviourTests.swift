import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// How an inline canvas carousel is moved through, driven from the shared fixtures
/// `inline_carousel_indicators/inline_carousel_indicators_scrolling` and `_jumping`. What it draws
/// for a slide this build cannot read is the package's
/// `Tests/DigiaEngageTests/FixtureBehaviour/InlineCarouselBehaviourTests.swift`.
///
/// The fixture is served by the mocked bundle, delivered the way a CEP does and drawn by the app's
/// own `DigiaSlot`; the carousel is swiped and tapped with real touches. Slide pictures are picsum
/// URLs that cannot load here, so a slide is told apart by the `Digia Step Viewed` the carousel
/// reports when it comes to rest on it.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_inline_test.dart` (its `inline carousel`
/// group) and `ui_carousel_indicators_test.dart`. Not ported from the latter: the per-effect
/// tests, `unknown_effect_falls_back` among them (iOS's `CanvasCarouselRenderer` reads `indicatorEffect` nowhere and draws every effect
/// as the same row of capsules, so there is no effect to tell apart) and the overflow tests
/// Flutter itself skips (iOS draws each dot at exactly `dotHeight`, inside the room it reserves).
@Suite(
    "Inline carousel",
    .serialized,
    .tags(.integration, .behaviour, .inline)
)
@MainActor
struct InlineCarouselBehaviourTests {

    /// Boots the SDK with [campaign], opens the page with its slot and delivers it.
    private func showCarousel(_ campaign: [String: Any]) async throws -> (SdkHarness, InlineSlotFrame) {
        let slot = try #require((campaign["templateConfig"] as? [String: Any])?["slotKey"] as? String)
        let sdk = try await SdkHarness.start(campaign)
        let frame = try sdk.mountInlineSlot(slot)
        try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntil("the card is in its slot") { sdk.sdk.inlineController.getCanvasConfig(slot) != nil }
        try await sdk.waitUntil("the card is laid out") { frame.frame.height > 1 }
        return (sdk, frame)
    }

    // MARK: - The indicator

    // Fails if: Sources/DigiaEngage/api/internal/canvas/CampaignCanvasStripViews.swift:391
    // `.scrollPosition(id: $scrollPosition)` -> `(deleted)` (the indicator and the reported slide
    // no longer follow the finger).
    @Test("swiping to the next slide moves the carousel and its indicator with it")
    func swipingMovesToTheNextSlide() async throws {
        let campaign = try fixture("inline_carousel_indicators/inline_carousel_indicators_scrolling")
        let (sdk, frame) = try await showCarousel(campaign)
        defer { sdk.tearDown() }
        let window = try #require(sdk.window)
        _ = try await sdk.waitForEvents("Digia Step Viewed", of: keyOf(campaign), count: 1)

        try TouchSynthesizer.drag(
            from: CGPoint(x: frame.frame.midX + 120, y: frame.frame.midY),
            by: CGVector(dx: -300, dy: 0),
            in: window,
            duration: 0.2,
            steps: 10,
            pauseAfterDown: 0.02
        )

        let viewed = try await sdk.waitForEvents("Digia Step Viewed", of: keyOf(campaign), count: 2)
        #expect(viewed.map { $0["item_index"] as? Int } == [1, 2])
    }

    /// Known gap: iOS's dots are drawn, not tappable (`CanvasCarouselRenderer` builds them as plain
    /// `Capsule`s with no gesture), where Flutter takes the carousel to the dot that was tapped.
    @Test("tapping a dot takes the carousel to that slide")
    func tappingADotMovesToItsSlide() async throws {
        let campaign = try fixture("inline_carousel_indicators/inline_carousel_indicators_jumping")
        let (sdk, frame) = try await showCarousel(campaign)
        defer { sdk.tearDown() }
        let window = try #require(sdk.window)
        _ = try await sdk.waitForEvents("Digia Step Viewed", of: keyOf(campaign), count: 1)

        // The third of three dots, each 12 wide with 6 between them, centred under the slides;
        // the row sits 2 pt above the card's 8 pt bottom margin.
        let dot = CGPoint(x: frame.frame.midX + (12 + 6), y: frame.frame.maxY - 8 - 2 - 4)
        try TouchSynthesizer.tap(at: dot, in: window)
        try await sdk.settle(0.8)

        let viewed = try await sdk.inlineEvents("Digia Step Viewed", of: keyOf(campaign))
        withKnownIssue("iOS carousel dots are not tappable") {
            #expect(viewed.last?["item_index"] as? Int == 3)
        }
    }
}
}
