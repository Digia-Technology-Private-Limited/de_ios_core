import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// What a story rail does for the person using the page, driven from the shared fixtures
/// `inline_story/inline_story_strip_bad_items_and_card_guards`,
/// `inline_story_single_image_guarded_styling` and
/// `inline_story_single_image_without_url_falls_back_to_strip`.
///
/// The fixture is served by the mocked bundle, delivered the way a CEP does, drawn by the app's own
/// `DigiaSlot`, and a card is tapped with a real touch. The proof is the frame the viewer opens on,
/// as the backend received it.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_inline_test.dart` (its `inline stories`
/// group).
@Suite(
    "Inline story rail",
    .serialized,
    .tags(.integration, .behaviour, .inline),
    .enabled(if: testkitAvailable, testkitSkipReason)
)
@MainActor
struct InlineStoryStripBehaviourTests {

    /// Boots the SDK with [name], opens the page with its slot, delivers it and waits for the rail.
    private func show(_ name: String) async throws -> (SdkHarness, InlineSlotFrame, InlineStoryConfig, String) {
        let campaign = try fixture("inline_story/\(name)")
        let template = try #require(campaign["templateConfig"] as? [String: Any])
        let slot = try #require(template["slotKey"] as? String)
        let sdk = try await SdkHarness.start(campaign)
        let frame = try sdk.mountInlineSlot(slot)
        try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntil("the story rail is in its slot") { sdk.sdk.inlineController.getStoryConfig(slot) != nil }
        let config = try #require(sdk.sdk.inlineController.getStoryConfig(slot))
        return (sdk, frame, config, keyOf(campaign))
    }

    /// Five items are authored: one with an empty URL, one with none, one whose URL is wrapped as
    /// `{"value": …}` and two plain ones. Flutter reads the wrapped URL, so three stay. Known gap:
    /// iOS reads a story item's `url` only as a plain string (`StoryItemConfig.fromJson`,
    /// `json.nonBlankString("url")`), so it drops the wrapped one too and keeps two. That the items
    /// without media are gone, and that a tap opens the item at its place among those that stayed,
    /// holds either way and is asserted unwrapped.
    // Fails if: Sources/DigiaEngage/api/internal/campaign/inline_story_config.swift:35
    // `guard let url = json.nonBlankString("url") else { return nil }` -> `let url = json["url"] as? String ?? ""`
    // (the items with no media stay in the rail, and the second card is the 2nd of five).
    @Test("items without media are dropped, and a tap opens the item at its place among the ones that stayed")
    func itemsWithoutMediaAreDropped() async throws {
        let (sdk, frame, config, key) = try await show("inline_story_strip_bad_items_and_card_guards")
        defer { sdk.tearDown() }

        #expect(config.items.allSatisfy { !$0.url.isEmpty })
        withKnownIssue("iOS does not read a story item URL wrapped as {\"value\": …}") {
            #expect(config.items.count == 3)
        }

        try await sdk.tapStoryCard(1, in: frame, card: config.card)
        try await sdk.waitForStoryViewer()

        #expect(try await sdk.storyFramesShown(key) == [InlineStoryFrame(2, config.items.count)],
                "the second remaining item, not the 2nd of five")
        try await sdk.closeStoryViewer()
    }

    /// Flutter draws a `previewMode: singleImage` story as one full-width preview image that opens
    /// the story at its first item. Known gap: iOS has no preview mode
    /// (`InlineStoryConfig.fromJson` never reads `previewMode` / `previewImage`), so it draws the
    /// usual rail of cards. The person can still open the story from it, which is asserted
    /// unwrapped; that it is one preview spanning the slot is the known issue.
    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:129
    // `.onTapGesture { onOpen(index) }` -> `.onTapGesture {}`
    @Test("a preview image opens the story at its first item")
    func previewImageOpensTheFirstItem() async throws {
        let (sdk, frame, config, key) = try await show("inline_story_single_image_guarded_styling")
        defer { sdk.tearDown() }
        try await sdk.waitUntil("the rail is laid out") { frame.frame.height > 1 }

        withKnownIssue("iOS has no single-image story preview; it draws the rail of cards") {
            // One preview, inset 12 pt each side of the slot, not a 132 pt card.
            #expect(CGFloat(config.card.width) >= frame.frame.width - 24)
        }

        try await sdk.tapStoryCard(0, in: frame, card: config.card)
        try await sdk.waitForStoryViewer()

        #expect(try await sdk.storyFramesShown(key) == [InlineStoryFrame(1, 1)])
        try await sdk.closeStoryViewer()
    }

    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:48
    // `initialIndex: index,` -> `initialIndex: 0,` (the second card opens the first item).
    @Test("a preview with no usable URL falls back to the strip of its items")
    func previewWithoutUrlFallsBackToTheStrip() async throws {
        let (sdk, frame, config, key) = try await show("inline_story_single_image_without_url_falls_back_to_strip")
        defer { sdk.tearDown() }

        #expect(config.items.count == 2)

        try await sdk.tapStoryCard(1, in: frame, card: config.card)
        try await sdk.waitForStoryViewer()

        #expect(try await sdk.storyFramesShown(key) == [InlineStoryFrame(2, 2)])
        try await sdk.closeStoryViewer()
    }
}
}
