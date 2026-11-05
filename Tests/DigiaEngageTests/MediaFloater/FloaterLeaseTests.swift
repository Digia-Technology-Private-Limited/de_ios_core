import AVFoundation
import Combine
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension RenderedUITests {
/// T9: the PiP's video and the shared window around it. The orchestrator borrows the showing's
/// player from the pool before the window shows; the window's `MediaVideo` joins that held
/// player under the same key. So expanding, collapsing, a rotation and a remount keep one player
/// and its playhead (N2), and both teardown paths give the player back.
///
/// Each test starts the Test Kit's `pip_mute_toggle` video (a local file, muted, autoplay) on the
/// SDK's floater orchestrator, over a fresh pool, and draws it with the production
/// `FloaterOverlayView` in a key window whose overlay a test can take down and put back (one host,
/// a state toggle: N2's lesson). It reads the players the window's layers draw.
///
/// Same names as Android's `FloaterLeaseTest` where the case is the same.
@Suite("PiP window: the leased video and the shared window", .serialized,
       .tags(.integration, .pip, .floater, .media),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct FloaterLeaseTests {

    /// Whether the overlay is mounted: the toggle a remount flips.
    @MainActor
    final class Mount: ObservableObject {
        @Published var shown = true
    }

    private struct Host: View {
        @ObservedObject var mount: Mount
        var body: some View {
            ZStack {
                Color.white
                if mount.shown { FloaterOverlayView() }
            }
            .ignoresSafeArea()
        }
    }

    private static let portrait = CGSize(width: 390, height: 844)
    private static let landscape = CGSize(width: 844, height: 390)

    private struct Showing {
        let orchestrator: FloaterOrchestrator
        let pool: VideoPlayerPool
        let window: UIWindow
        let mount: Mount
        let key: String
    }

    /// Starts the PiP over a fresh pool and waits for its window to be drawn and its video to
    /// play past [playedPast] seconds. Every cleanup is registered in [cleanups].
    private func show(
        _ overrides: [([String], Any)] = [], playedPast: Double = 0.5,
        cleanups: inout [() -> Void]
    ) async throws -> Showing {
        let pool = VideoPlayerPool(maxPlayers: 3, makeItem: { AVPlayerItem(url: $0) })
        MediaServices.override(videoPool: pool)
        cleanups.append { MediaServices.reset() }
        setGeometry(Self.portrait)
        cleanups.append { activeFloaterWindowGeometryOverride = nil }

        let json = try floaterFixture("pip/pip_mute_toggle", setting: overrides)
        let campaign = try #require(try CampaignModel.fromJson(json, designTokens: fixtureTokens(json)))
        let orchestrator = try #require(SDKInstance.shared.floaterOrchestrator)
        let started = orchestrator.start(
            campaign,
            payload: CEPTriggerPayload(cepCampaignId: "test_pip", campaignKey: campaign.campaignKey, cepMetadata: [:]),
            screenName: nil)
        try #require(started, "refused: \(orchestrator.lastStartFailureReason ?? "unknown")")
        let active = try #require(orchestrator.state)
        let key = floaterVideoPlayerKey(active)

        let mount = Mount()
        let window = ComponentTestHost.makeWindow(frame: CGRect(origin: .zero, size: Self.portrait))
        window.rootViewController = UIHostingController(rootView: Host(mount: mount))
        window.makeKeyAndVisible()
        // The showing ends while its window is still mounted, so the window's `MediaVideo` gives
        // its hold back and `activeRect` clears before the window goes: nothing is left playing
        // or published for the next suite.
        cleanups.append {
            orchestrator.dispose()
            ComponentTestHost.drainRunLoop(for: 0.2)
            window.rootViewController = nil
            window.isHidden = true
        }

        try await waitFor("the window is drawn") { !orchestrator.awaitingMedia && orchestrator.activeRect != nil }
        try await waitFor("the video plays past \(playedPast) s") {
            (orchestrator.player?.currentTime().seconds ?? 0) > playedPast && (orchestrator.player?.rate ?? 0) > 0
        }
        return Showing(orchestrator: orchestrator, pool: pool, window: window, mount: mount, key: key)
    }

    private func setGeometry(_ size: CGSize) {
        activeFloaterWindowGeometryOverride = (CGRect(origin: .zero, size: size), EdgeInsets())
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Every `AVPlayerLayer` the window draws a player into.
    private func playerLayers(in window: UIWindow) -> [AVPlayerLayer] {
        var layers: [AVPlayerLayer] = []
        func walk(_ layer: CALayer) {
            if let playerLayer = layer as? AVPlayerLayer, playerLayer.player != nil { layers.append(playerLayer) }
            layer.sublayers?.forEach(walk)
        }
        walk(window.layer)
        return layers
    }

    // Fails if the window plays any player but the one the orchestrator leased:
    // floater_media_view.swift `playerKey: videoPlayerKey` -> `playerKey: nil` (the window builds
    // its own keyless player, a second one, beside the orchestrator's).
    @Test("the window receives the already-playing player by key")
    func windowReceivesTheAlreadyPlayingPlayerByKey() async throws {
        var cleanups: [() -> Void] = []
        defer { cleanups.reversed().forEach { $0() } }
        let showing = try await show(cleanups: &cleanups)
        let leased = try #require(showing.orchestrator.player)

        let layers = playerLayers(in: showing.window)
        #expect(layers.count == 1, "one video drawn")
        #expect(layers.first?.player === leased, "the window draws the leased player")
        #expect(showing.pool.heldKeys == [showing.key])
        #expect(showing.pool.livePlayerCount == 1, "no second player")
    }

    // Fails if a content swap rebuilds the window's content: floater_overlay_view.swift
    // `.environment(\.digiaCampaignKey, state.campaign.campaignKey)` on `FloaterMediaView` ->
    // the same line plus `.id(expanded)` (the media becomes a branch on the surface, so growing to
    // full screen remounts it on a new layer).
    @Test("a content swap keeps the window, its video layer and its playhead")
    func aContentSwapKeepsTheWindowAndItsVideo() async throws {
        var cleanups: [() -> Void] = []
        defer { cleanups.reversed().forEach { $0() } }
        let showing = try await show(cleanups: &cleanups)
        let orchestrator = showing.orchestrator
        orchestrator.moveTo(FloaterFraction(x: 0, y: 0))
        try await Task.sleep(nanoseconds: 300_000_000)
        let layer = try #require(playerLayers(in: showing.window).first)
        let before = layer.player?.currentTime().seconds ?? 0

        orchestrator.expand()
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(playerLayers(in: showing.window).first === layer, "the same layer full screen")
        orchestrator.collapse()
        try await Task.sleep(nanoseconds: 800_000_000)

        let after = try #require(playerLayers(in: showing.window).first)
        #expect(after === layer, "the same layer back in the window")
        #expect(after.player === orchestrator.player)
        #expect((after.player?.currentTime().seconds ?? 0) > before, "the video carried on")
        let rect = try #require(orchestrator.activeRect)
        #expect(rect.origin == CGPoint(x: 16, y: 16), "back in the corner it was dragged to: \(rect)")
    }

    // Fails if a rotation loses the committed corner: FloatingWindow.swift `floatingRestingRect`
    // `if let drag = dragFraction {` -> `if false, let drag = dragFraction {` (the window goes back
    // to its configured bottom-right). The player half is guarded by the remount test below.
    @Test("a rotation keeps the window in its corner and the video at its position")
    func rotationKeepsTheWindowInItsCornerAndTheVideoAtItsPosition() async throws {
        var cleanups: [() -> Void] = []
        defer { cleanups.reversed().forEach { $0() } }
        let showing = try await show(cleanups: &cleanups)
        let orchestrator = showing.orchestrator
        let token = try #require(orchestrator.state?.token)
        orchestrator.moveTo(FloaterFraction(x: 0, y: 0))
        let leased = try #require(orchestrator.player)
        let before = leased.currentTime().seconds

        setGeometry(Self.landscape)
        showing.window.frame = CGRect(origin: .zero, size: Self.landscape)
        showing.window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)

        #expect(orchestrator.state?.token == token, "the same showing")
        let rect = try #require(orchestrator.activeRect)
        #expect(rect.origin == CGPoint(x: 16, y: 16), "top-left of the landscape screen: \(rect)")
        #expect(abs(rect.width - Self.landscape.width * 0.35) < 0.5, "sized for the new screen")
        #expect(playerLayers(in: showing.window).first?.player === leased)
        #expect(leased.currentTime().seconds > before, "not restarted")
    }

    // Fails if a remount restarts the video (N2): floater_media_view.swift
    // `playerKey: videoPlayerKey` -> `playerKey: nil` (the remounted window builds a new player,
    // which starts at 0). One host, the overlay toggled out and back in.
    @Test("a rotation remount resumes the leased player at its position")
    func rotationRemountResumesTheLeasedPlayerAtItsPosition() async throws {
        var cleanups: [() -> Void] = []
        defer { cleanups.reversed().forEach { $0() } }
        let showing = try await show(playedPast: 1.5, cleanups: &cleanups)
        let leased = try #require(showing.orchestrator.player)

        showing.mount.shown = false
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(playerLayers(in: showing.window).isEmpty, "the overlay went")
        let before = leased.currentTime().seconds
        showing.mount.shown = true
        try await waitFor("the window is drawn again") { !playerLayers(in: showing.window).isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)

        let player = try #require(playerLayers(in: showing.window).first?.player)
        #expect(player === leased, "the same player")
        #expect(player.currentTime().seconds >= before, "resumed, not restarted at 0")
        #expect(showing.pool.livePlayerCount == 1)
    }

    // Fails if a teardown path keeps the lease held: floater_orchestrator.swift `finishDismiss`
    // `releaseLease()` -> removed (and `dispose` likewise for its half). A held key keeps its
    // player counted in the pool for the life of the process.
    @Test("teardown releases the lease on both paths")
    func teardownReleasesTheLeaseOnBothPaths() async throws {
        var cleanups: [() -> Void] = []
        defer { cleanups.reversed().forEach { $0() } }
        let first = try await show(cleanups: &cleanups)
        first.orchestrator.dismiss(.userClose)
        try await waitFor("the showing ends") { first.orchestrator.state == nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(first.pool.heldKeys.isEmpty, "dismiss gave the player back")

        cleanups.reversed().forEach { $0() }
        cleanups = []
        let second = try await show(cleanups: &cleanups)
        second.mount.shown = false
        try await Task.sleep(nanoseconds: 300_000_000)
        second.orchestrator.dispose()
        #expect(second.pool.heldKeys.isEmpty, "dispose gave the player back")
    }

    // Fails if a video that cannot load is shown anyway or keeps its player (OD-4):
    // floater_orchestrator.swift `preparePlayer` `case .failed:` -> `case .failed where false:`
    // (the window waits out the 10 s media timeout with the lease held).
    @Test("a video that fails before the window shows is never shown and gives its player back")
    func aVideoThatFailsToLoadIsNeverShown() async throws {
        let pool = VideoPlayerPool(maxPlayers: 3, makeItem: { AVPlayerItem(url: $0) })
        MediaServices.override(videoPool: pool)
        defer { MediaServices.reset() }
        let json = try floaterFixture(
            "pip/pip_mute_toggle", setting: [(["media", "url"], floaterTestkitAsset("t9-missing.mp4"))])
        let campaign = try #require(try CampaignModel.fromJson(json, designTokens: fixtureTokens(json)))
        let orchestrator = try #require(SDKInstance.shared.floaterOrchestrator)
        defer { orchestrator.dispose() }
        #expect(orchestrator.start(
            campaign,
            payload: CEPTriggerPayload(cepCampaignId: "test_pip", campaignKey: campaign.campaignKey, cepMetadata: [:]),
            screenName: nil))

        try await waitFor("the campaign is dropped", timeout: 5) { orchestrator.state == nil }
        #expect(orchestrator.lastStartFailureReason?.contains("video failed to load") == true)
        #expect(pool.heldKeys.isEmpty, "its player went back to the pool")
    }

    // Fails if a video's end no longer reaches the orchestrator: floater_orchestrator.swift
    // `preparePlayer` `self?.onVideoEnded(token: token)` -> removed (the showing outlives its media).
    @Test("a video that plays to its end ends the showing as its media ending")
    func aVideoThatEndsEndsTheShowing() async throws {
        var cleanups: [() -> Void] = []
        defer { cleanups.reversed().forEach { $0() } }
        let showing = try await show(
            [(["media", "loop"], false), (["behavior", "onMediaEnd"], "dismiss")], cleanups: &cleanups)
        let player = try #require(showing.orchestrator.player)
        let duration = try #require(player.currentItem?.duration.seconds)
        await player.seek(to: CMTime(seconds: duration - 0.6, preferredTimescale: 600))

        try await waitFor("the showing ends at the video's end", timeout: 6) { showing.orchestrator.state == nil }
    }

    // Fails if a looping video no longer starts over: floater_media_view.swift `loop: media.loop`
    // -> `loop: false` (the window's `MediaVideo` owns the loop; the orchestrator has none).
    @Test("a looping video starts over at its end and the showing stays")
    func aLoopingVideoStartsOverAtItsEnd() async throws {
        var cleanups: [() -> Void] = []
        defer { cleanups.reversed().forEach { $0() } }
        let showing = try await show([(["media", "loop"], true)], cleanups: &cleanups)
        let player = try #require(showing.orchestrator.player)
        let duration = try #require(player.currentItem?.duration.seconds)
        await player.seek(to: CMTime(seconds: duration - 0.6, preferredTimescale: 600))

        try await waitFor("the video starts over", timeout: 6) {
            player.currentTime().seconds < 1 && player.rate > 0
        }
        #expect(showing.orchestrator.isShowing)
    }
}
}
