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

    // MARK: - The rail's thumbnails

    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:114
    // `onWindowCompleted: { playbackStore.send(.windowCompleted(index)) },` -> `onWindowCompleted: {},`
    @Test("the videos take turns, each from its authored start, and the rotation wraps past the last one")
    func videosTakeTurns() async throws {
        let strip = try await show()
        defer { strip.sdk.tearDown() }

        let first = try await strip.untilPlaying(1)
        #expect(strip.watch.starts == ["card 0 from 0s"])

        // The first video plays to its end, so the second takes over.
        await inlineRunOut(first.player)
        let second = try await strip.untilPlaying(2)
        #expect(strip.watch.starts == ["card 0 from 0s", "card 1 from 2s"])

        // The second is a 3 s slice from 2 s: it is still on short of 5 s, and over at 5 s.
        await second.player.seek(to: CMTime(value: 4_600, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero)
        try await strip.sdk.settle(0.15)
        #expect(strip.watch.played.count == 2, "the window is not over yet")
        let third = try await strip.untilPlaying(3)
        #expect(strip.watch.starts == ["card 0 from 0s", "card 1 from 2s", "card 2 from 0s"])

        // After the last video, the rotation comes back to the first, then the second again.
        await inlineRunOut(third.player)
        let fourth = try await strip.untilPlaying(4)
        await inlineRunOut(fourth.player)
        _ = try await strip.untilPlaying(5)
        #expect(strip.watch.starts == [
            "card 0 from 0s", "card 1 from 2s", "card 2 from 0s", "card 0 from 0s", "card 1 from 2s",
        ])
        try await strip.finish()
    }

    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:116
    // `playbackStore.send(.failed(index: index, identity: playerIdentity))` -> `(deleted)`
    @Test("a video that fails is skipped for the rest of the rotation")
    func failedVideoIsSkipped() async throws {
        // The first video cannot be opened, so the rail moves on to the second.
        let strip = try await show { $0[0]["url"] = Self.unplayable }
        defer { strip.sdk.tearDown() }

        let first = try await strip.untilPlaying(1)
        #expect(strip.watch.starts == ["card 1 from 2s"])

        await first.player.seek(to: CMTime(value: 4_600, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero)
        let second = try await strip.untilPlaying(2)
        await inlineRunOut(second.player)
        _ = try await strip.untilPlaying(3)

        // The rotation is now the second and third videos only: the broken first one is not
        // given another turn.
        #expect(strip.watch.starts == ["card 1 from 2s", "card 2 from 0s", "card 1 from 2s"])
        try await strip.finish()
    }

    // Fails if: Sources/DigiaEngage/api/internal/campaign/inline_story_thumbnail_playback.swift:238
    // `state.sequentialActiveIndex = mode == .sequential` (in `restartFromFirst`) -> `(deleted)`
    @Test("going to the background stops the video, and coming back starts the rotation over from the first one")
    func backgroundRestartsTheRotation() async throws {
        let strip = try await show()
        defer { strip.sdk.tearDown() }
        let first = try await strip.untilPlaying(1)
        await inlineRunOut(first.player)
        _ = try await strip.untilPlaying(2)
        #expect(strip.watch.starts == ["card 0 from 0s", "card 1 from 2s"])

        InlineAppLifecycle.resignActive()
        try await strip.sdk.waitUntil("the rail lets go of its player") {
            strip.sdk.storyPlayers(in: strip.frame, card: strip.config.card).isEmpty
        }
        try await strip.sdk.settle(0.5)
        #expect(strip.watch.played.count == 2, "nothing new starts while away")

        InlineAppLifecycle.becomeActive()
        _ = try await strip.untilPlaying(3)

        #expect(strip.watch.starts.last == "card 0 from 0s", "not the second video it was on, but the first")
        try await strip.finish()
    }

    // Fails if: Sources/DigiaEngage/api/internal/campaign/inline_story_thumbnail_playback.swift:204
    // `reconcileActive()` (in the `.failed` case) -> `(deleted)` (the rail stays on the broken first
    // video and never tries the others).
    @Test("a video the player cannot open is let go of, and the strip carries on with the next one")
    func unopenableVideosAreReleased() async throws {
        let strip = try await show { items in
            for index in 0..<3 { items[index]["url"] = Self.unplayable }
        }
        defer { strip.sdk.tearDown() }

        // Three videos, each tried once, each released.
        try await strip.sdk.waitUntil("each video has failed", timeout: 8) {
            strip.sdk.records(strip.key, reason: TimelineReason.mediaLoadFailed).count >= 3
        }
        try await strip.sdk.settle(0.5)

        #expect(strip.sdk.records(strip.key, reason: TimelineReason.mediaLoadFailed).count == 3)
        #expect(strip.sdk.storyPlayers(in: strip.frame, card: strip.config.card).isEmpty,
                "a player that failed to open is released, not left behind")
        #expect(strip.watch.played.isEmpty)
        try await strip.finish()
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
        try InlineTouch.press(at: CGPoint(x: window.bounds.midX, y: window.bounds.midY), in: window, for: 0.7) {
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

    /// Flutter times a frame whose video cannot be fetched like a picture — its 8 s — and then
    /// moves on. Known gap: iOS moves on the moment the player fails (`InlineStoryVideoView` falls
    /// back to `onEnded` when no `onFailed` is given), so the frame is not shown for its time.
    /// That the story does not stall on it holds on iOS and is asserted unwrapped.
    // Fails if: Sources/DigiaEngage/api/widgets/DigiaInlineStoryView.swift:1009
    // `if let onFailed { onFailed() } else { onEnded?() }` -> `if let onFailed { onFailed() }`
    // (the story then stalls: its watchdog only runs once a first video frame was shown).
    @Test("a video that cannot be fetched does not stall the story, which moves on")
    func unfetchableViewerVideoMovesOn() async throws {
        let strip = try await show { $0[0]["url"] = Self.missing }
        defer { strip.sdk.tearDown() }
        let sdk = strip.sdk

        try await sdk.tapStoryCard(0, in: strip.frame, card: strip.config.card)
        try await sdk.waitForStoryViewer()
        try await sdk.settle(1)
        let early = try await sdk.storyFramesShown(strip.key)
        withKnownIssue("iOS skips a failed video frame at once instead of timing it like a picture") {
            #expect(early == [InlineStoryFrame(1, 4)], "the first video item lasts 8 s")
        }

        let frames = try await sdk.waitForEvents("Digia Step Viewed", of: strip.key, count: 2, timeout: 10)
            .map { InlineStoryFrame($0["item_index"] as? Int ?? -1, $0["item_total"] as? Int) }
        // Both frames were shown. Their order and count on the wire are not asserted: when the
        // first video fails as the viewer opens, iOS reports the first frame twice and, at times,
        // the second one before them.
        #expect(Set(frames.map(\.description)) == ["(1, 4)", "(2, 4)"])
        try await strip.finish()
    }
}
}
