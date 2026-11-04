import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// What a person can do to a picture-in-picture window, and what it does in return. Each test
/// boots the real SDK, delivers the fixture the way a CEP does and lets `DigiaHost` render it; the
/// person then taps, drags, swipes or waits. Asserted: the orchestrator's state, what is on screen,
/// and the reason the showing's `CampaignPresentation` settles with.
///
/// Fixtures (`sdk_testing_fixtures/campaigns/pip/`): `pip_close_dismiss`, `pip_auto_dismiss`,
/// `pip_mute_toggle`, `pip_media_expand`, `pip_expand_off_free_drop`, `pip_initial_expanded`,
/// `pip_video_chrome_pinned_height`. Their image and video are the Test Kit's. What the window does
/// untouched (its timeout, the screens it survives, its pinned size) is the package's
/// `Tests/DigiaEngageTests/FixtureBehaviour/PipSurfaceBehaviourTests.swift`.
///
/// iOS has no system Back for an in-app window; the expanded PiP's swipe-down strip is its Back
/// (`expandedChrome` routes it to `expanded.onBack`), so the Back tests swipe. Timings run on the
/// wall clock, so each window is asserted inside a band rather than at an instant.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_pip_test.dart`.
@Suite("PiP surface behaviour", .serialized, .tags(.integration, .behaviour, .pip, .floater),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct PipSurfaceBehaviourTests {

    private func boot(
        _ json: [String: Any], screen: String? = nil
    ) async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.start(json)
        do {
            let presentation = try sdk.deliverFloater(keyOf(json), screen: screen)
            return (sdk, presentation)
        } catch {
            sdk.tearDown()
            throw error
        }
    }

    // MARK: - pip_close_dismiss

    // Fails if: Sources/DigiaEngage/api/widgets/floater_overlay_view.swift `collapsedChrome` ×
    // `SDKInstance.shared.dismissFloater(.userClose)` -> `.dismissFloater(.autoTimeout)`.
    @Test("pip_close_dismiss: the × ends the showing, reported as the user closing it")
    func closeEndsTheShowing() async throws {
        let (sdk, presentation) = try await boot(try fixture("pip/pip_close_dismiss"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()

        try sdk.tapFloater(at: try sdk.pipCloseButton())

        try await sdk.waitUntil("the PiP is gone", timeout: 6) { sdk.pip.state == nil }
        #expect(presentation.dismissReason == .userClose)
        #expect(sdk.isShowing("App home"))
    }

    // MARK: - pip_auto_dismiss

    // Fails if: floater_orchestrator.swift `restartAutoDismiss`
    // `guard let afterMs = state?.config.behavior.autoDismissAfterMs, surface != .expanded` ->
    // `guard let afterMs = state?.config.behavior.autoDismissAfterMs`.
    @Test("pip_auto_dismiss: stops counting while full screen and starts over in full when it collapses")
    func autoDismissPausesWhileExpanded() async throws {
        let (sdk, presentation) = try await boot(try fixture("pip/pip_auto_dismiss"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()

        try await sdk.settle(1.5)
        try sdk.tapFloaterWindow()
        #expect(sdk.pip.surface == .expanded)

        try await sdk.settle(4)
        #expect(sdk.pip.isShowing, "someone watching full screen is not timed out")

        // Default `closePlacement: top_right`: the × is the rightmost control; `onClose` collapses.
        try sdk.tapFloater(at: try #require(sdk.expandedPipTopRow().last))
        #expect(sdk.pip.surface == .collapsed)
        let collapsedAt = Date()

        try await sdk.settle(2.6)
        #expect(sdk.pip.isShowing, "the clock restarted at the collapse, not at the start")
        try await sdk.waitUntil("the PiP times out", timeout: 2) { !sdk.pip.isShowing }
        #expect(floaterElapsed(since: collapsedAt) < 3.7)
        #expect(presentation.dismissReason == .autoTimeout)
    }

    // MARK: - pip_mute_toggle

    // Fails if: floater_orchestrator.swift `setMuted` `player?.isMuted = value` ->
    // `player?.isMuted = true`, or `player?.volume = value ? 0 : active.config.media.volume` ->
    // `player?.volume = 0`.
    @Test("pip_mute_toggle: the mute button flips the sound of the playing video")
    func muteFlipsTheSound() async throws {
        let (sdk, _) = try await boot(try fixture("pip/pip_mute_toggle"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        #expect(sdk.pip.muted, "authored startMuted")
        let player = try #require(sdk.pip.player)
        #expect(player.isMuted)

        // The mute pill sits bottom-right, whatever `mutePlacement` says: iOS fixes the corners.
        let rect = try sdk.pipRect()
        let mute = try sdk.floaterButton(in: rect, nearest: CGPoint(x: rect.maxX, y: rect.maxY))
        try sdk.tapFloater(at: mute)

        #expect(!sdk.pip.muted)
        #expect(!player.isMuted)
        #expect(player.volume > 0)

        try sdk.tapFloater(at: mute)

        #expect(sdk.pip.muted)
        #expect(player.isMuted)
        #expect(player.volume == 0)
    }

    // MARK: - pip_media_expand

    // Fails if: Sources/DigiaEngage/api/internal/model/floater_config.swift
    // `FloaterExpandedClose.from` `value == "dismiss" ? .dismiss : .collapse` ->
    // `value == "dismiss" ? .dismiss : .dismiss`.
    @Test("pip_media_expand: a tap opens full screen and the × collapses it again")
    func tapExpandsAndCloseCollapses() async throws {
        let (sdk, _) = try await boot(try fixture("pip/pip_media_expand"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()

        try sdk.tapFloaterWindow()
        #expect(sdk.pip.surface == .expanded)
        try await sdk.settle(0.6)

        try sdk.tapFloater(at: try #require(sdk.expandedPipTopRow().last))

        #expect(sdk.pip.surface == .collapsed)
        #expect(sdk.pip.isShowing)
    }

    // Fails if: floater_overlay_view.swift `commitDrag` `fx = projectedFx >= 0.5 ? 1 : 0` -> `fx = 0`.
    @Test("pip_media_expand: a short, slow drag settles back into the same corner")
    func shortSlowDragSnapsBack() async throws {
        let (sdk, _) = try await boot(try fixture("pip/pip_media_expand"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        let rect = try sdk.pipRect()

        try TouchSynthesizer.drag(
            from: CGPoint(x: rect.midX, y: rect.midY), by: CGVector(dx: -60, dy: 0),
            in: try #require(sdk.window), duration: 0.4, hold: 0.3)
        try await sdk.waitUntil("the drop is recorded", timeout: 6) { sdk.pip.dragFraction != nil }

        #expect(sdk.pip.dragFraction == FloaterFraction(x: 1, y: 1))
        #expect(sdk.pip.surface == .collapsed, "dragging is not a tap")
    }

    // Fails if: floater_overlay_view.swift `commitDrag` `fx = projectedFx >= 0.5 ? 1 : 0` -> `fx = 1`.
    @Test("pip_media_expand: a drag past the middle snaps to the opposite edge")
    func dragPastTheMiddleSnapsAcross() async throws {
        let (sdk, _) = try await boot(try fixture("pip/pip_media_expand"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        let rect = try sdk.pipRect()

        try TouchSynthesizer.drag(
            from: CGPoint(x: rect.midX, y: rect.midY), by: CGVector(dx: -250, dy: 0),
            in: try #require(sdk.window), duration: 0.5, hold: 0.3)
        try await sdk.waitUntil("the drop is recorded", timeout: 6) { sdk.pip.dragFraction != nil }

        #expect(sdk.pip.dragFraction == FloaterFraction(x: 0, y: 1))
    }

    // Fails if: floater_overlay_view.swift `handlePan` `width: translation.width + velocity.x * 0.18`
    // -> `width: translation.width`.
    @Test("pip_media_expand: a fast fling snaps to the corner it was thrown at, even from a short drag")
    func flingSnapsToTheThrownCorner() async throws {
        let (sdk, _) = try await boot(try fixture("pip/pip_media_expand"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        let rect = try sdk.pipRect()

        try TouchSynthesizer.drag(
            from: CGPoint(x: rect.midX, y: rect.midY), by: CGVector(dx: -60, dy: 0),
            in: try #require(sdk.window), duration: 0.04, steps: 4)
        try await sdk.waitUntil("the drop is recorded", timeout: 6) { sdk.pip.dragFraction != nil }

        #expect(sdk.pip.dragFraction?.x == 0)
    }

    // MARK: - pip_expand_off_free_drop

    // Fails if: floater_config.swift `tapExpands: (onTap?.string("type", default: "expand") ??
    // "expand") == "expand"` -> `tapExpands: true`.
    @Test("pip_expand_off_free_drop: a tap does not open it when the author turned expanding off")
    func tapDoesNotExpandWhenTurnedOff() async throws {
        let (sdk, _) = try await boot(try fixture("pip/pip_expand_off_free_drop"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()

        try sdk.tapFloaterWindow()
        try await sdk.settle(0.3)

        #expect(sdk.pip.surface == .collapsed)
        #expect(sdk.pip.isShowing)
    }

    // Fails if: floater_overlay_view.swift `commitDrag` `if config.controls.snapToCorner {` ->
    // `if true {`.
    @Test("pip_expand_off_free_drop: with snapping off, a drop stays where it was let go")
    func freeDropStaysWhereReleased() async throws {
        let (sdk, _) = try await boot(try fixture("pip/pip_expand_off_free_drop"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        let rect = try sdk.pipRect()

        try TouchSynthesizer.drag(
            from: CGPoint(x: rect.midX, y: rect.midY), by: CGVector(dx: 100, dy: -200),
            in: try #require(sdk.window), duration: 0.5, hold: 0.3)
        try await sdk.waitUntil("the drop is recorded", timeout: 6) { sdk.pip.dragFraction != nil }

        let fraction = try #require(sdk.pip.dragFraction)
        #expect(fraction.x > 0 && fraction.x < 1, "x \(fraction.x)")
        #expect(fraction.y > 0 && fraction.y < 1, "y \(fraction.y)")
    }

    // MARK: - pip_initial_expanded

    // Fails if: floater_config.swift `FloaterExpandedClose.from` `value == "dismiss" ? .dismiss :
    // .collapse` -> `value == "dismiss" ? .dismiss : .dismiss`.
    @Test("pip_initial_expanded: opens full screen, and the × collapses it by default")
    func initialExpandedCloseCollapses() async throws {
        let (sdk, _) = try await boot(try fixture("pip/pip_initial_expanded"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        #expect(sdk.pip.surface == .expanded)

        try sdk.tapFloater(at: try #require(sdk.expandedPipTopRow().last))

        #expect(sdk.pip.surface == .collapsed)
        #expect(sdk.pip.isShowing)
    }

    // Fails if: floater_overlay_view.swift `expandedChrome` swipe strip
    // `SDKInstance.shared.endFloaterExpanded(config.expanded.onBack)` -> `.endFloaterExpanded(.dismiss)`.
    @Test("pip_initial_expanded: swiping down (iOS's Back) collapses it by default")
    func initialExpandedSwipeDownCollapses() async throws {
        let (sdk, presentation) = try await boot(try fixture("pip/pip_initial_expanded"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        #expect(sdk.pip.surface == .expanded)

        try sdk.swipeDownExpandedPip()

        try await sdk.waitUntil("full screen collapses", timeout: 6) { sdk.pip.surface == .collapsed }
        #expect(sdk.pip.isShowing)
        #expect(presentation.dismissReason == nil)
    }

    // MARK: - pip_video_chrome_pinned_height

    private func bootPinned() async throws -> (SdkHarness, CampaignPresentation) {
        try await boot(try fixture("pip/pip_video_chrome_pinned_height"))
    }

    private func expand(_ sdk: SdkHarness) async throws {
        try sdk.tapFloaterWindow()
        #expect(sdk.pip.surface == .expanded)
        // The transition runs the default 500 ms; the chrome takes taps once it has landed.
        try await sdk.settle(0.7)
    }

    // Fails if: floater_orchestrator.swift `togglePlayback`
    // `if player.rate > 0 { player.pause() } else { player.play() }` ->
    // `if player.rate > 0 { player.play() } else { player.pause() }`.
    @Test("pip_video_chrome_pinned_height: showPlayPause toggles the video")
    func playPauseToggles() async throws {
        let (sdk, _) = try await bootPinned()
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        try await sdk.waitUntil("autoplay starts", timeout: 6) { sdk.pip.isPlaying }

        // Bottom-right pill: play/pause, then mute.
        let rect = try sdk.pipRect()
        let pill = try sdk.floaterButtons(in: rect).filter { $0.x > rect.midX && $0.y > rect.midY }
        try #require(pill.count == 2, "play/pause and mute: \(pill)")
        try sdk.tapFloater(at: pill[0])

        try await sdk.waitUntil("the video pauses", timeout: 6) { !sdk.pip.isPlaying }
        #expect(sdk.pip.player?.rate == 0)

        try sdk.tapFloater(at: pill[0])

        try await sdk.waitUntil("the video plays again", timeout: 6) { sdk.pip.isPlaying }
    }

    // Fails if: floater_config.swift `closeOnLeft: j.string("closePlacement", default: "top_right")
    // == "top_left"` -> `== "x"`.
    @Test("pip_video_chrome_pinned_height: top_left puts the × on the left and collapse on the right")
    func closeOnTheLeftCollapseOnTheRight() async throws {
        let (sdk, _) = try await bootPinned()
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        try await expand(sdk)
        let width = try #require(sdk.window).bounds.width

        let row = try sdk.expandedPipTopRow()
        try #require(row.count >= 2, "expanded chrome row: \(row)")
        #expect(row[0].x < width / 2, "the × is on the left")
        let rightSide = row.filter { $0.x > width / 2 }
        try #require(!rightSide.isEmpty, "no controls on the right")

        // The right-hand pill leads with collapse.
        try sdk.tapFloater(at: rightSide[0])

        #expect(sdk.pip.surface == .collapsed)
        #expect(sdk.pip.isShowing)
    }

    // Fails if: floater_overlay_view.swift `expandedChrome` swipe strip
    // `SDKInstance.shared.endFloaterExpanded(config.expanded.onBack)` ->
    // `.endFloaterExpanded(config.expanded.onClose)`.
    @Test("pip_video_chrome_pinned_height: swiping down collapses full screen although the × would end it")
    func swipeDownCollapsesAlthoughCloseDismisses() async throws {
        let (sdk, presentation) = try await bootPinned()
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        try await expand(sdk)

        try sdk.swipeDownExpandedPip()

        try await sdk.waitUntil("full screen collapses", timeout: 6) { sdk.pip.surface == .collapsed }
        #expect(sdk.pip.isShowing)
        #expect(presentation.dismissReason == nil)
    }

    // Fails if: floater_overlay_view.swift `expandedChrome` × `SDKInstance.shared.endFloaterExpanded(
    // config.expanded.onClose)` -> `.endFloaterExpanded(config.expanded.onBack)`.
    @Test("pip_video_chrome_pinned_height: the × ends the showing as the user closing it")
    func expandedCloseEndsTheShowing() async throws {
        let (sdk, presentation) = try await bootPinned()
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        try await expand(sdk)

        try sdk.tapFloater(at: try #require(sdk.expandedPipTopRow().first))

        try await sdk.waitUntil("the PiP is gone", timeout: 6) { sdk.pip.state == nil }
        #expect(presentation.dismissReason == .userClose)
    }

    /// Flutter also asserts the leaving window ignores taps (`IgnorePointer`). iOS's equivalent —
    /// the shield's `gestureRecognizerShouldBegin` refusing while `closing` — cannot be reached by
    /// a touch here: the window's published rect jumps to its off-screen end at once, so no touch
    /// lands on it. That half is not ported.
    // Fails if: floater_overlay_view.swift `runExitAnimation`
    // `if flies { flyOffsetFraction = flyOffset(exit.to) }` ->
    // `if flies { flyOffsetFraction = flyOffset(config.collapsed.entryAnimation.from) }`.
    @Test("pip_video_chrome_pinned_height: a window closed from its corner × flies out to the left")
    func closedWindowFliesOutLeft() async throws {
        let (sdk, _) = try await bootPinned()
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        let before = try sdk.pipRect()

        try sdk.tapFloater(at: try sdk.pipCloseButton())

        #expect(!sdk.pip.isShowing, "the showing ended at the tap")
        let during = try #require(sdk.pip.activeRect, "gone before its 250 ms exit")
        #expect(during.midX < before.midX - 20, "moving left while it closes")
        #expect(during.midY == before.midY, "and only sideways")
        try await sdk.waitUntil("the exit finishes", timeout: 6) { sdk.pip.state == nil }
    }
}
}
