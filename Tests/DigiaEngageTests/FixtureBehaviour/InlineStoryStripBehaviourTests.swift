import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// What a story rail reports before anyone touches it, driven from the shared fixture
/// `inline_story/inline_story_strip_bad_items_and_card_guards`. The fixture is served by the mocked
/// bundle, delivered the way a CEP does and drawn by the app's own `DigiaSlot`. Tapping a card is the
/// sample app's `InlineStoryStripBehaviourTests`.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_inline_test.dart` (its `inline stories`
/// group).
@Suite(
    "Inline story rail: impressions",
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

    /// Flutter reports the rail's item count on its `Digia Experience Viewed`. Known gap: iOS
    /// builds `StoriesEvent.Viewed` without `itemTotal`
    /// (`Sources/DigiaEngage/api/internal/SDKInstance.swift`, `reportSlotFirstRender`, the
    /// `.story` case), so the event goes out with no `item_total`. `withKnownIssue` fails the day
    /// iOS sends it, as the cue to drop the wrapper.
    @Test("the rail's impression counts only the items that stayed")
    func impressionCountsTheItemsThatStayed() async throws {
        let (sdk, _, config, key) = try await show("inline_story_strip_bad_items_and_card_guards")
        defer { sdk.tearDown() }

        let viewed = try await sdk.waitForEvents("Digia Experience Viewed", of: key, count: 1)
        withKnownIssue("iOS sends a story's Digia Experience Viewed without item_total") {
            #expect(viewed.first?["item_total"] as? Int == config.items.count)
        }
    }
}
}
