import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// What the full-screen story viewer does for the person using it, driven from the shared fixtures
/// `inline_story/inline_story_swipe_next`, `inline_story_auto_advance`, `inline_story_cta_url` and
/// `inline_story_close_button`.
///
/// The fixture is served by the mocked bundle, delivered the way a CEP does, drawn by the app's own
/// `DigiaSlot`, and opened by tapping its first card. Every gesture is a real touch on the viewer
/// the SDK presented over the app; the proof is what the backend received and what the host app
/// was asked to do. The fixtures' picsum images cannot load here, which these tests are not about.
///
/// iOS taps an 88 pt zone at each edge to go back or on (Flutter splits the screen in halves), so
/// the taps land at a tenth of the width from each edge, inside both.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_story_viewer_test.dart`.
@Suite(
    "Story viewer",
    .serialized,
    .tags(.integration, .behaviour, .inline),
    .enabled(if: testkitAvailable, testkitSkipReason)
)
@MainActor
struct StoryViewerBehaviourTests {

    private static let back: CGFloat = 0.1
    private static let on: CGFloat = 0.9

    /// Boots the SDK with [name] (its template changed by [edit] first), opens the page with the
    /// rail, delivers it, taps the first card and waits for the viewer.
    private func openViewer(
        _ name: String,
        edit: (inout [String: Any]) -> Void = { _ in }
    ) async throws -> (SdkHarness, String) {
        var campaign = try fixture("inline_story/\(name)")
        var template = try #require(campaign["templateConfig"] as? [String: Any])
        edit(&template)
        campaign["templateConfig"] = template
        let slot = try #require(template["slotKey"] as? String)
        let sdk = try await SdkHarness.start(campaign)
        let frame = try sdk.mountInlineSlot(slot)
        try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntil("the story rail is in its slot") { sdk.sdk.inlineController.getStoryConfig(slot) != nil }
        let config = try #require(sdk.sdk.inlineController.getStoryConfig(slot))
        try await sdk.tapStoryCard(0, in: frame, card: config.card)
        try await sdk.waitForStoryViewer()
        return (sdk, keyOf(campaign))
    }

    // MARK: - Moving between frames

    /// Known gap: going back from the first frame stays on it without telling the backend it was
    /// shown again (`previous()` moves to index 0, the index does not change, and the
    /// `StoryStepViewedReporter` in `DigiaInlineStoryView.swift` reports only a change), where
    /// Flutter reports the first frame a second time.
    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:780
    // `.onTapGesture { next() }` -> `.onTapGesture { previous() }`
    @Test("the right edge goes on, the left edge goes back, and going back from the first frame shows it again")
    func edgesMoveBetweenFrames() async throws {
        let (sdk, key) = try await openViewer("inline_story_swipe_next")
        defer { sdk.tearDown() }

        try sdk.tapStoryViewer(atFraction: Self.on)
        try sdk.tapStoryViewer(atFraction: Self.back)
        try sdk.tapStoryViewer(atFraction: Self.back)

        let frames = try await sdk.storyFramesShown(key)
        #expect(Array(frames.prefix(3)) == [InlineStoryFrame(1, 2), InlineStoryFrame(2, 2), InlineStoryFrame(1, 2)])
        #expect(sdk.storyViewerIsOpen)
        withKnownIssue("iOS does not report the first frame again when going back from it") {
            #expect(frames == [InlineStoryFrame(1, 2), InlineStoryFrame(2, 2), InlineStoryFrame(1, 2), InlineStoryFrame(1, 2)])
        }
        try await sdk.closeStoryViewer()
    }

    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:821
    // `completed = true` -> `(deleted)` (the close is then reported as a dismissal too).
    @Test("going on from the last frame completes the story once and closes the viewer, without reporting it as dismissed")
    func lastFrameCompletesAndCloses() async throws {
        let (sdk, key) = try await openViewer("inline_story_swipe_next")
        defer { sdk.tearDown() }
        #expect(sdk.storyViewerIsOpen)

        try sdk.tapStoryViewer(atFraction: Self.on)
        try sdk.tapStoryViewer(atFraction: Self.on)

        try await sdk.waitForStoryViewerClosed()
        TouchSynthesizer.drainRunLoop(for: 0.5)
        let completed = try await sdk.inlineEvents("Digia Experience Completed", of: key)
        #expect(completed.count == 1)
        #expect(completed.first?["item_total"] as? Int == 2)
        #expect(try await sdk.inlineEvents("Digia Step Dismissed", of: key).isEmpty)
        try await sdk.closeStoryViewer()
    }

    /// Known gap: a story set to restart goes round again without ever reporting completion
    /// (`next()` in `DigiaInlineStoryView.swift` takes the `restartOnCompleted` branch before the
    /// one that reports `Completed`), where Flutter reports it the first time round.
    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:818
    // `} else if state.config.restartOnCompleted {` -> `} else if false {` (it closes instead).
    @Test("a story set to restart starts again after its last frame, and reports completion only the first time round")
    func restartingStoryGoesRoundAgain() async throws {
        let (sdk, key) = try await openViewer("inline_story_swipe_next") { $0["restartOnCompleted"] = true }
        defer { sdk.tearDown() }

        // Two laps: on, on and round again, on, on and round again.
        for _ in 0..<4 { try sdk.tapStoryViewer(atFraction: Self.on) }

        #expect(sdk.storyViewerIsOpen, "it starts over, not closes")
        #expect(try await sdk.storyFramesShown(key) == [
            InlineStoryFrame(1, 2), InlineStoryFrame(2, 2), InlineStoryFrame(1, 2),
            InlineStoryFrame(2, 2), InlineStoryFrame(1, 2),
        ])
        let completed = try await sdk.inlineEvents("Digia Experience Completed", of: key)
        withKnownIssue("iOS never reports completion of a story that restarts") {
            #expect(completed.count == 1)
        }
        #expect(try await sdk.inlineEvents("Digia Step Dismissed", of: key).isEmpty)
        try await sdk.closeStoryViewer()
    }

    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:800
    // `if elapsed >= currentDuration {` -> `if false {`
    @Test("a frame moves on by itself when its time is up, and the last one closes the viewer")
    func framesAdvanceOnTheirOwn() async throws {
        let (sdk, key) = try await openViewer("inline_story_auto_advance")
        defer { sdk.tearDown() }

        // Each of the two frames is on for 3 s.
        try await sdk.settle(3.1)
        #expect(sdk.storyViewerIsOpen, "one frame is still to come")
        try await sdk.waitForStoryViewerClosed(timeout: 4)

        #expect(try await sdk.storyFramesShown(key) == [InlineStoryFrame(1, 2), InlineStoryFrame(2, 2)])
        #expect(try await sdk.inlineEvents("Digia Experience Completed", of: key).count == 1)
        try await sdk.closeStoryViewer()
    }

    // MARK: - Holding and leaving

    /// Known gap: iOS has no hold-to-pause. The viewer's only touch handlers are the edge tap zones
    /// and a drag to dismiss (`InlineStoryOverlayContent` in `DigiaInlineStoryView.swift`), and
    /// `tick()` runs the frame's timer under a finger, so a held frame moves on after 3 s.
    @Test("holding a frame freezes its timer, and letting go carries on")
    func holdingFreezesTheFrame() async throws {
        let (sdk, key) = try await openViewer("inline_story_auto_advance")
        defer { sdk.tearDown() }
        let window = try #require(sdk.window)

        try TouchSynthesizer.press(at: CGPoint(x: window.bounds.midX, y: window.bounds.midY), in: window, for: 5)
        let held = try await sdk.storyFramesShown(key)
        try await sdk.settle(3.1)
        let released = try await sdk.storyFramesShown(key)

        withKnownIssue("iOS has no hold-to-pause on the story viewer") {
            #expect(held == [InlineStoryFrame(1, 2)], "five seconds held, still on the first frame")
            #expect(released == [InlineStoryFrame(1, 2), InlineStoryFrame(2, 2)])
            #expect(sdk.storyViewerIsOpen, "the second frame has run 3 s of its 3 s at most")
        }
        try await sdk.closeStoryViewer()
    }

    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:685
    // `let swipeDown = dy > 48 && dy > abs(dx)` -> `let swipeDown = false`
    @Test("swiping down closes the viewer and reports the frame it was left on as dismissed")
    func swipeDownDismisses() async throws {
        let (sdk, key) = try await openViewer("inline_story_swipe_next")
        defer { sdk.tearDown() }
        let window = try #require(sdk.window)
        try sdk.tapStoryViewer(atFraction: Self.on)

        try TouchSynthesizer.drag(
            from: CGPoint(x: window.bounds.midX, y: window.bounds.height * 0.35),
            by: CGVector(dx: 0, dy: 300),
            in: window,
            duration: 0.15,
            steps: 10,
            pauseAfterDown: 0.02
        )

        try await sdk.waitForStoryViewerClosed()
        // The viewer reports its dismissal as it leaves the screen, after the SDK let go of it.
        let dismissed = try await sdk.waitForEvents("Digia Step Dismissed", of: key, count: 1)
        #expect(dismissed.map { $0["item_index"] as? Int } == [2])
        #expect(try await sdk.inlineEvents("Digia Experience Completed", of: key).isEmpty)
        try await sdk.closeStoryViewer()
    }

    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:653
    // `action: { SDKInstance.shared.controller.dismissStoryOverlay() }` -> `action: {}`
    @Test("the close button closes the viewer when the story shows one")
    func closeButtonCloses() async throws {
        let (sdk, _) = try await openViewer("inline_story_close_button") {
            $0["closeButton"] = ["visible": true, "size": 32]
        }
        defer { sdk.tearDown() }

        #expect(!sdk.isShowing("Mute story"), "no sound controls on an image story")
        try await sdk.tapStoryButton("Close story", position: 0, indicator: StoryIndicatorDisplayConfig())

        try await sdk.waitForStoryViewerClosed()
        try await sdk.closeStoryViewer()
    }

    // MARK: - The call to action

    /// The fixture's own `ctaAction` is `Action.openUrl` with a `data` block, which the legacy
    /// `ctaAction` reader does not understand and treats as "just close"; Flutter's test moves the
    /// same link into the item's `onClick` steps. Known gap: iOS does not read a story item's
    /// `onClick` (`StoryItemConfig.fromJson` reads action steps only from `ctaAction.steps`), so the
    /// button just closes the story. The click report, which iOS sends, is asserted unwrapped.
    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:850
    // `SDKInstance.shared.reportStoryStepClicked(` -> `(deleted)`
    @Test("runs the action the story authored and reports the click on the frame it was on")
    func ctaRunsItsActionAndReportsTheClick() async throws {
        let (sdk, key) = try await openViewer("inline_story_cta_url") { template in
            var items = template["items"] as? [[String: Any]] ?? []
            items[0].removeValue(forKey: "ctaAction")
            items[0]["onClick"] = ["steps": [[
                "type": "Action.openUrl",
                "data": ["url": "https://medihub.example.com/wellness", "launchMode": "externalApplication"],
            ]]]
            template["items"] = items
        }
        defer { sdk.tearDown() }
        let opened = Received<String>()
        sdk.setOpenURLHandler { opened.append($0) }

        try await sdk.tapStoryCTA("Visit Portal")
        try await sdk.settle(0.3)

        let clicks = try await sdk.waitForEvents("Digia Step Clicked", of: key, count: 1)
        #expect(clicks.count == 1)
        #expect(clicks.first?["item_index"] as? Int == 1)
        #expect(clicks.first?["cta_label"] as? String == "Visit Portal")
        withKnownIssue("iOS does not read a story item's onClick steps") {
            #expect(opened.values == ["https://medihub.example.com/wellness"])
            #expect(sdk.storyViewerIsOpen, "the story stays open")
        }
        try await sdk.closeStoryViewer()
    }

    // Fails if: Sources/DigiaEngage/api/internal/campaign/inline_story_config.swift:79
    // `default: [.dismiss]` -> `default: []`
    @Test("a button with no destination just closes the story, and the click is still reported")
    func ctaWithoutDestinationCloses() async throws {
        let (sdk, key) = try await openViewer("inline_story_auto_advance")
        defer { sdk.tearDown() }

        try await sdk.tapStoryCTA("First Offer")

        // Well before the frame's own 3 s run out would close it.
        try await sdk.waitForStoryViewerClosed(timeout: 1.5)
        let clicks = try await sdk.waitForEvents("Digia Step Clicked", of: key, count: 1)
        #expect(clicks.count == 1)
        #expect(clicks.first?["item_index"] as? Int == 1)
        #expect(clicks.first?["cta_label"] as? String == "First Offer")
        try await sdk.closeStoryViewer()
    }
}
}
