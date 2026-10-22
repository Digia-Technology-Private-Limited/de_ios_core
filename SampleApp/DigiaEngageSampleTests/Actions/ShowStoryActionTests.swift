import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// `showStory`: the escape hatch for a story campaign whose rail is off — any element the author
/// draws can open the stories instead. The `actions/fixtures/action_show_story` card is
/// `inline-story-home` with its rail off and the card covered by a tap region authored to open the
/// *second* story.
///
/// Story one carries the only text in the fixture ("Shop Now"), so the viewer opening on story two
/// is visible from the outside: the viewer is presented and that text is not on screen.
@Suite("ShowStory action", .serialized, .tags(.actions, .integration))
@MainActor
struct ShowStoryActionTests {

    @Test("tapping an element authored with showStory opens the viewer at that story")
    func showStoryOpensTheViewerAtThatStory() async throws {
        let sdk = try await SdkHarness.start(
            loadCampaign("Actions/Fixtures/action_show_story.json"))
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot("test_inline_stories") { EmptyView() } }
        try sdk.deliver("test_action_show_story")
        #expect(sdk.presentedViewer == nil)

        try await sdk.tap(id: "open_second_story")

        try await sdk.waitUntil("the story viewer is presented") { sdk.presentedViewer != nil }
        TouchSynthesizer.drainRunLoop(for: 0.5)
        #expect(!sdk.isShowing("Shop Now"))
    }
}
}
