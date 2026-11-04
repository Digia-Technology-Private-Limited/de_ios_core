import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// What an inline canvas carousel draws for a slide this build cannot read, driven from the shared
/// fixture `inline_carousel/inline_carousel_unreadable_slide_drops_carousel`. The fixture is served by
/// the mocked bundle, delivered the way a CEP does and drawn by the app's own `DigiaSlot`. Swiping and
/// tapping the carousel is the sample app's `InlineCarouselBehaviourTests`.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_inline_test.dart` (its `inline carousel`
/// group).
@Suite(
    "Inline carousel: unreadable slides",
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

    // Fails if: Sources/DigiaEngage/api/internal/canvas/CampaignCanvasParser.swift:52
    // `guard let parsed = try? parse(slide) else { return nil }` -> `guard let parsed = try? parse(slide) else { continue }`
    @Test("one slide from a newer schema drops the carousel and not the rest of the canvas")
    func unreadableSlideDropsOnlyTheCarousel() async throws {
        let (sdk, _) = try await showCarousel(
            fixture("inline_carousel/inline_carousel_unreadable_slide_drops_carousel"))
        defer { sdk.tearDown() }

        try await sdk.waitUntil("the heading is on screen") {
            sdk.isShowing("Featured offers (carousel below must not render)")
        }
        #expect(!sdk.isShowing("Slide 1"))
    }

    @Test("the same carousel renders once every slide is readable")
    func readableSlidesRender() async throws {
        var campaign = try fixture("inline_carousel/inline_carousel_unreadable_slide_drops_carousel")
        campaign["templateConfig"] = Self.settingSlideVersion(campaign["templateConfig"], slide: 1, to: 2)
        let (sdk, _) = try await showCarousel(campaign)
        defer { sdk.tearDown() }

        try await sdk.waitUntil("the first slide is on screen") { sdk.isShowing("Slide 1") }
    }

    /// [node] with the version of the [slide]th slide of the carousel inside it set to [version].
    private static func settingSlideVersion(_ node: Any?, slide: Int, to version: Int) -> Any? {
        if var map = node as? [String: Any] {
            if var slides = map["slides"] as? [[String: Any]] {
                slides[slide]["version"] = version
                map["slides"] = slides
                return map
            }
            for (key, value) in map { map[key] = settingSlideVersion(value, slide: slide, to: version) }
            return map
        }
        if let list = node as? [Any] { return list.map { settingSlideVersion($0, slide: slide, to: version) } }
        return node
    }
}
}
