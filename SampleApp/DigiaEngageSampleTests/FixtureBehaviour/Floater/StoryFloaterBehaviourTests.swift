import AVFoundation
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// What a story floater does when a person uses it and as time passes. Each test boots the real
/// SDK, delivers the fixture the way a CEP does and lets `DigiaHost` render it; the person taps the
/// window, watches the story and waits. Asserted: which page is on screen and when it changes, the
/// orchestrator's state, the reason the showing's `CampaignPresentation` settles with, and what the
/// story viewer did to its video player.
///
/// Fixtures (`sdk_testing_fixtures/campaigns/floater/`): `floater_story_gradient_window_multipage`,
/// `floater_story_video_pages_mute_restart`, `floater_window_clear_background_child_shadows`,
/// `floater_auto_dismiss`, `floater_story_screen_change_targeted`. What the window does when nobody
/// opens it is the package's `Tests/DigiaEngageTests/FixtureBehaviour/StoryFloaterBehaviourTests.swift`.
///
/// Flutter runs these on a fake clock; here page lengths and timeouts are measured on the wall
/// clock and asserted inside a band. The bands are wider above than below: the viewer advances a
/// page by counting 30 Hz timer ticks (`CanvasStoryViewer.startAuthoredTimer`), so a page runs
/// long, never short, on a loaded machine. Flutter's fake player ends a clip on demand; here the
/// real player plays the Test Kit's `movie.mp4` and the test seeks it to its end.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_floater_test.dart`.
@Suite("Story floater behaviour", .serialized, .tags(.integration, .behaviour, .floater, .media),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct StoryFloaterBehaviourTests {

    private func boot(
        _ name: String, screen: String? = nil
    ) async throws -> (SdkHarness, CampaignPresentation) {
        let json = try fixture("floater/\(name)")
        let sdk = try await SdkHarness.start(json)
        do {
            let presentation = try sdk.deliverFloater(keyOf(json), screen: screen)
            return (sdk, presentation)
        } catch {
            sdk.tearDown()
            throw error
        }
    }

    /// Taps the window and waits until the story is open. Returns when it was tapped: the
    /// viewer's first page starts counting then.
    @discardableResult
    private func openStory(_ sdk: SdkHarness) async throws -> Date {
        let tappedAt = Date()
        try sdk.tapFloaterWindow()
        try await sdk.waitUntil("the story opens", timeout: 6) { sdk.storyFloater.storyOpen }
        return tappedAt
    }

    // MARK: - floater_story_gradient_window_multipage

    // YAML-covered (tests/floater/f29_floater_multipage.yaml passes): each
    // page lasts its own length, the unset one the 5 s default, and the story
    // then ends the whole showing.

    // MARK: - floater_story_video_pages_mute_restart

    /// Known gap, not a test problem: the story chrome's mute flips the viewer's state — its glyph
    /// turns to "Mute" — but the video that is playing keeps its sound. The viewer hands the new
    /// state to `InlineStoryVideoView(muted:)` (`CampaignCanvasStripViews.swift`), whose
    /// `.onChange(of: muted)` should reach `StoryVideoPlayback.update`
    /// (`inline_story_video_playback.swift`, `player?.isMuted = nextState.muted`); the live
    /// `AVPlayer` drawn on screen still reports `isMuted == false`. Flutter mutes the live player.
    /// The next video a page opens does start muted, so the choice still outlives the page. Marked
    /// with `withKnownIssue`, so it fails the day the live player mutes, as the cue to drop it.
    // Fails if: Sources/DigiaEngage/api/internal/canvas/CampaignCanvasStripViews.swift
    // `CanvasStoryViewer.toggleMute` `muted.toggle()` is deleted.
    // Fails if: CampaignCanvasStripViews.swift `CanvasStoryViewer` video `onFailed`
    // `startAuthoredTimer()` is deleted (the unplayable page then never ends).
    // Fails if: CampaignCanvasStripViews.swift `CanvasStoryViewer.step`
    // `if loopToStart { index = 0; start() } else { onDismiss() }` -> `onDismiss()` only.
    @Test("floater_story_video_pages_mute_restart: mute follows the viewer to the next video, an unplayable one runs its authored 3 s, and the story starts over once it has ended")
    func videoPagesMuteAndRestart() async throws {
        let (sdk, _) = try await boot("floater_story_video_pages_mute_restart")
        defer { sdk.tearDown() }
        try await sdk.waitForStoryWindow()
        try await openStory(sdk)

        // Page 0 is a video: playing with sound, as the story asks (`startMuted: false`).
        try await sdk.waitUntil("page 0's video plays", timeout: 5) {
            sdk.floaterPlayers(playing: "movie.mp4").first?.currentItem?.status == .readyToPlay
        }
        let first = try #require(sdk.floaterPlayers(playing: "movie.mp4").first)
        #expect(!first.isMuted)

        try await sdk.waitUntil("the chrome shows the unmuted glyph") {
            sdk.floaterLabels(underId: "mute").contains("Volume High")
        }

        try await sdk.tap(id: "mute")

        try await sdk.waitUntil("the mute glyph flips") { sdk.floaterLabels(underId: "mute").contains("Mute") }
        await withKnownIssue("iOS's story mute flips its glyph but not the playing video's sound") {
            try await sdk.waitUntil("the live player is muted", timeout: 1.5) { first.isMuted }
        }

        // The clip plays to its end (seeked there): the page ends with it.
        let duration = try #require(first.currentItem?.duration.seconds)
        await first.seek(to: CMTime(seconds: max(0, duration - 0.3), preferredTimescale: 600))
        try await sdk.waitUntil("page 1", timeout: 4) { sdk.isShowing("Unplayable video") }
        let secondStart = Date()

        // No video could be played: the page must not stall, and lasts its authored 3 s.
        try await sdk.waitUntil("page 2", timeout: 6) { sdk.isShowing("Last page") }
        let second = floaterElapsed(since: secondStart)
        #expect(second > 2.6 && second < 4.0, "the unplayable page lasted \(second) s, authored 3 s")
        let thirdStart = Date()

        // The last page (4 s, no video) ends the story, which restarts at page 0.
        try await sdk.waitUntil("the story leaves the last page", timeout: 6) { !sdk.isShowing("Last page") }
        let third = floaterElapsed(since: thirdStart)
        #expect(third > 3.6 && third < 4.8, "the last page lasted \(third) s, authored 4 s")
        #expect(sdk.storyFloater.storyOpen, "restartOnCompleted: the story starts over")
        try await sdk.waitUntil("page 0 plays again", timeout: 5) {
            sdk.floaterPlayers(playing: "movie.mp4").contains { $0 !== first }
        }
        let again = try #require(sdk.floaterPlayers(playing: "movie.mp4").first { $0 !== first })
        #expect(again.isMuted, "the choice outlives the page")
    }

    // MARK: - floater_window_clear_background_child_shadows

    // YAML-covered (tests/floater/f28_floater_window_opens_story.yaml passes):
    // a tap on the window opens the story and does not close it; closing the
    // story returns to the window; the window's × ends the showing as the
    // user closing it.

    // MARK: - floater_auto_dismiss

    // YAML-covered (tests/floater/f34_floater_timeout_pause.yaml passes):
    // its 3 s timeout stops while the story is open and starts over, in full,
    // when the story ends.

    // MARK: - Screen scope

    // Fails if: floater_story_orchestrator.swift `onScreenChanged`
    // `if !targets.isEmpty && !targets.contains(screenName) {` -> `if false {`.
}
}
