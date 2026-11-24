import AVFoundation
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// How a story rail plays its video thumbnails, and how the full-screen viewer plays a video frame,
/// driven from the shared fixture `inline_story/inline_story_video_thumbnails`.
///
/// The fixture is served by the mocked bundle, delivered the way a CEP does and drawn by the app's
/// own `DigiaSlot`. Nothing is faked below the SDK: its videos are the Test Kit's `movie.mp4`
/// (12.6 s) on disk, played by real `AVPlayer`s, which the tests find on screen in the SDK's
/// `InlineStoryPlayerContainer`s. Where the Flutter tests move a fake player's playhead, these seek
/// the real one (`inlineRunOut`).
///
/// The fixture's rail is sequential and has three video items, in this order: the whole video from
/// 0, a 3 s window starting at 2 s, and the whole video from 0 again, followed by an image.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_inline_video_thumbnails_test.dart`,
/// `surface_story_video_viewer_test.dart` and `surface_story_video_viewer_fallback_test.dart`.
/// The other `surface_story_video_*` files test the video cache through a loopback origin that holds,
/// breaks off or oversizes a download; iOS's cache (`DigiaVideoFileCache.shared`) cannot be pointed
/// at such an origin from here, and is covered on its own by `DigiaVideoFileCacheTests`.
@Suite(
    "Inline story video",
    .serialized,
    .tags(.integration, .behaviour, .inline, .media),
    .enabled(if: testkitAvailable, testkitSkipReason)
)
@MainActor
struct InlineStoryVideoBehaviourTests {

    private static let name = "inline_story_video_thumbnails"

    /// A file AVFoundation cannot open as a video: the Test Kit's JPEG.
    private static var unplayable: String {
        FixtureLoader.resolveAssetOrigin(
            in: "{{TESTKIT_ASSET_ORIGIN}}/assets/strawberry.jpg", workspaceUrl: FixtureLoader.workspaceURL())
    }

    /// A video that is not there to fetch.
    private static var missing: String {
        FixtureLoader.resolveAssetOrigin(
            in: "{{TESTKIT_ASSET_ORIGIN}}/assets/inline-behaviour-missing.mp4", workspaceUrl: FixtureLoader.workspaceURL())
    }

    @MainActor
    private struct Strip {
        let sdk: SdkHarness
        let frame: InlineSlotFrame
        let config: InlineStoryConfig
        let key: String
        let watch: InlinePlayerWatch

        func untilPlaying(_ count: Int, timeout: TimeInterval = 6) async throws -> InlineSeenPlayer {
            try await sdk.waitUntil("player \(count) is playing", timeout: timeout) { watch.playing(count) != nil }
            return try #require(watch.playing(count))
        }

        func finish() async throws {
            watch.stop()
            try await sdk.closeStoryViewer()
        }
    }

    /// Opens the app with the rail on its page and delivers the fixture, its items changed by
    /// [edit] first.
    private func show(edit: (inout [[String: Any]]) -> Void = { _ in }) async throws -> Strip {
        var campaign = try fixture("inline_story/\(Self.name)")
        var template = try #require(campaign["templateConfig"] as? [String: Any])
        var items = try #require(template["items"] as? [[String: Any]])
        edit(&items)
        template["items"] = items
        campaign["templateConfig"] = template
        let slot = try #require(template["slotKey"] as? String)
        let sdk = try await SdkHarness.start(campaign)
        let frame = try sdk.mountInlineSlot(slot)
        try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntil("the story rail is in its slot") { sdk.sdk.inlineController.getStoryConfig(slot) != nil }
        let config = try #require(sdk.sdk.inlineController.getStoryConfig(slot))
        try await sdk.waitUntil("the rail is laid out") { frame.frame.height > 1 }
        return Strip(
            sdk: sdk, frame: frame, config: config, key: keyOf(campaign),
            watch: InlinePlayerWatch(sdk, slot: frame, card: config.card))
    }

    // MARK: - The viewer's video

    /// Two known gaps. The mute button flips its label at once, but the player follows one press
    /// late: muted after "Unmute", with sound after "Mute". `InlineStoryVideoView`
    /// (`DigiaInlineStoryView.swift:988`, `.onChange(of: muted) { _ in updatePlayback() }`) seems to read
    /// `muted` off a stale view value (most likely the one from before the change).
    /// And iOS has no hold-to-pause (see `StoryViewerBehaviourTests`), so holding the frame leaves
    /// the video playing. Everything else here holds on iOS and is asserted unwrapped.
    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:644
    // `action: { muteOverride = !muted }` -> `action: {}`
    @Test("plays with sound, and the person can mute it, hold it, leave the app and let it run out")
    func viewerVideoPlaysAndRunsOut() async throws {
        let strip = try await show()
        defer { strip.sdk.tearDown() }
        let sdk = strip.sdk
        let window = try #require(sdk.window)
        _ = try await strip.untilPlaying(1)

        // Open the first story: the rail's own players make way for the viewer's.
        try await sdk.tapStoryCard(0, in: strip.frame, card: strip.config.card)
        try await sdk.waitForStoryViewer()
        try await sdk.waitUntil("the viewer's video is playing", timeout: 6) {
            strip.watch.played.contains { $0.card == nil }
        }
        // The viewer's player, as it is on screen now.
        func viewer() -> AVPlayer? {
            sdk.storyPlayers(in: strip.frame, card: strip.config.card).first { $0.card == nil }?.player
        }
        #expect(viewer()?.isMuted == false, "the story does not start muted")
        #expect(sdk.storyPlayers(in: strip.frame, card: strip.config.card).allSatisfy { $0.card == nil })

        // Mute, then unmute.
        try await sdk.tapStoryButton("Mute story", position: 1, indicator: strip.config.indicator)
        try await sdk.waitUntil("the button offers to unmute") { sdk.isShowing("Unmute story") }
        let mutedAfterMute = viewer()?.isMuted
        try await sdk.tapStoryButton("Unmute story", position: 1, indicator: strip.config.indicator)
        try await sdk.waitUntil("the button offers to mute again") { sdk.isShowing("Mute story") }
        try await sdk.settle(0.3)
        let mutedAfterUnmute = viewer()?.isMuted
        withKnownIssue("iOS applies the mute button to the viewer's player one press late") {
            #expect(mutedAfterMute == true)
            #expect(mutedAfterUnmute == false)
        }

        // Holding the frame pauses the video, letting go plays it again.
        var rateWhileHeld: Float = -1
        try TouchSynthesizer.press(at: CGPoint(x: window.bounds.midX, y: window.bounds.midY), in: window, for: 0.7) {
            rateWhileHeld = viewer()?.rate ?? -1
        }
        withKnownIssue("iOS has no hold-to-pause on the story viewer") {
            #expect(rateWhileHeld == 0)
        }
        try await sdk.waitUntil("the video plays after the hold") { (viewer()?.rate ?? 0) > 0 }

        // Leaving the app stops it, and coming back plays it again.
        InlineAppLifecycle.resignActive()
        try await sdk.waitUntil("the video stops while away") { viewer()?.rate == 0 }
        InlineAppLifecycle.becomeActive()
        try await sdk.waitUntil("the video plays again") { (viewer()?.rate ?? 0) > 0 }

        // The video runs to its end, so the story moves on to the next frame.
        await inlineRunOut(try #require(viewer()))
        let frames = try await sdk.waitForEvents("Digia Step Viewed", of: strip.key, count: 2)
        #expect(frames.map { InlineStoryFrame($0["item_index"] as? Int ?? -1, $0["item_total"] as? Int) }
                == [InlineStoryFrame(1, 4), InlineStoryFrame(2, 4)])
        try await strip.finish()
    }
}
}
