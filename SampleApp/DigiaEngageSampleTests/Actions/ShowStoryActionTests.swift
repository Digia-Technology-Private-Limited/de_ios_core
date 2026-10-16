import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// `showStory`: the escape hatch for a story campaign whose rail is off — any element the author
/// draws can open the stories instead. The Test Kit has no such fixture, so this takes
/// `inline-story-home`, turns its rail off, and covers the card with a tap region authored to open
/// the *second* story.
///
/// Story one carries the only text in the fixture ("Shop Now"), so the viewer opening on story two
/// is visible from the outside: the viewer is presented and that text is not on screen.
@Suite("ShowStory action", .serialized, .tags(.actions, .integration))
@MainActor
struct ShowStoryActionTests {

    @Test("tapping an element authored with showStory opens the viewer at that story")
    func showStoryOpensTheViewerAtThatStory() async throws {
        var campaign = try ActionCampaigns.load("inline_story", "inline-story-home")
        try ActionCampaigns.editCanvasChild(in: &campaign, id: "story_widget") { child in
            var widget = child["widget"] as? [String: Any] ?? [:]
            var props = widget["props"] as? [String: Any] ?? [:]
            props["showRail"] = false
            widget["props"] = props
            child["widget"] = widget
        }
        try ActionCampaigns.editChildren(in: &campaign) { children in
            children.append([
                "kind": "tapRegion",
                "id": "open_second_story",
                "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
                "onClick": ["steps": [["type": "Action.showStory", "data": ["index": 1]]]],
            ])
        }
        let sdk = try await ActionHarness.start(campaign)
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot("test_inline_stories") { EmptyView() } }
        try sdk.deliver("test_inline_story")
        #expect(sdk.presentedViewer == nil)

        try await sdk.tap(id: "open_second_story")

        try await sdk.waitUntil("the story viewer is presented") { sdk.presentedViewer != nil }
        TouchSynthesizer.drainRunLoop(for: 0.5)
        #expect(!sdk.isShowing("Shop Now"))
    }
}
}
