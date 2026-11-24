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
}
}
