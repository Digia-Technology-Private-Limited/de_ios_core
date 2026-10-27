import AVKit
import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// What a canvas card's embedded video does, driven from the shared fixture
/// `canvas/canvas_video_player`: a muted, looping, non-autoplaying player with controls, fitted to
/// contain. The fixture is served by the scripted bundle, delivered the way a CEP does and drawn by
/// the app's own `DigiaSlot`. Only the AVPlayer side effects are replaced, through the SDK's own
/// seam (`CanvasVideoRuntime`, set on the app's environment): the renderer and its
/// `AVPlayerViewController` stay real. A test that changes how the video is authored edits that
/// one widget's props in the loaded fixture.
///
/// Not ported: Flutter's "a player that fails while the card is up" needs a player that errors on
/// demand, which a real `AVPlayer` cannot be made to do; the renderer-level suite
/// (`CanvasVideoRendererTests`) covers the iOS player in more depth.
///
/// Port of `flutter/core/test/fixture_behaviour/ui_canvas_video_test.dart`.
@Suite("Canvas: video player", .serialized,
       .tags(.integration, .behaviour, .canvas, .media),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct CanvasVideoPlayerBehaviourTests {

    /// Records what the card asks of its player; hands back an empty `AVPlayer`, so nothing plays.
    @MainActor
    final class Probe {
        private(set) var items: [AVPlayerItem] = []
        private(set) var players: [AVPlayer] = []
        private(set) var urls: [URL] = []
        var plays = 0
        var pauses = 0
        var restarts = 0

        var runtime: CanvasVideoRuntime {
            CanvasVideoRuntime(
                makePlayer: { item in
                    self.items.append(item)
                    if let asset = item.asset as? AVURLAsset { self.urls.append(asset.url) }
                    let player = AVPlayer()
                    self.players.append(player)
                    return player
                },
                play: { _ in self.plays += 1 },
                pause: { _ in self.pauses += 1 },
                restart: { _ in self.restarts += 1 }
            )
        }
    }

    /// Delivers the fixture, with [author] changing its video's props, over a card whose players go
    /// to [probe] (the live runtime when nil). Returns the harness and the authored video URL.
    private func show(
        probe: Probe?, author: (inout [String: Any]) -> Void = { _ in }
    ) async throws -> (SdkHarness, String) {
        var campaign = try fixture("canvas/canvas_video_player")
        var template = try #require(campaign["templateConfig"] as? [String: Any])
        var canvas = try #require(template["canvas"] as? [String: Any])
        var children = try #require(canvas["children"] as? [[String: Any]])
        var child = children[0]
        var widget = try #require(child["widget"] as? [String: Any])
        var props = try #require(widget["props"] as? [String: Any])
        author(&props)
        let url = try #require((props["source"] as? [String: Any])?["url"] as? String)
        widget["props"] = props
        child["widget"] = widget
        children[0] = child
        canvas["children"] = children
        template["canvas"] = canvas
        campaign["templateConfig"] = template

        let sdk = try await SdkHarness.start(campaign)
        try sdk.mount {
            if let probe {
                DigiaSlot("home_banner") { EmptyView() }.environment(\.canvasVideoRuntime, probe.runtime)
            } else {
                DigiaSlot("home_banner") { EmptyView() }
            }
        }
        try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntil("the card is on screen") { sdk.isShowing("Embedded Video Player") }
        if let probe {
            try await sdk.waitUntil("the card's player is made") { !probe.players.isEmpty }
        }
        return (sdk, url)
    }

    /// Ends the item the card's player is on, as AVFoundation does when the video reaches its end.
    private func playToEnd(_ probe: Probe) throws {
        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime, object: try #require(probe.items.last))
        TouchSynthesizer.drainRunLoop(for: 0.1)
    }

    // Fails if: CampaignCanvasView.swift `CanvasVideoRenderer.setup` drops `value.isMuted = muted`.
    @Test("the authored mute, loop and autoplay reach the player: this card opens silent, looping and waiting to be played")
    func authoredPlaybackReachesThePlayer() async throws {
        let probe = Probe()
        let (sdk, url) = try await show(probe: probe)
        defer { sdk.tearDown() }

        #expect(probe.urls.map(\.absoluteString) == [url])
        #expect(probe.players.count == 1)
        #expect(probe.players.first?.isMuted == true)
        #expect(probe.plays == 0, "autoplay is off")
        try playToEnd(probe)
        #expect(probe.restarts == 1, "it loops")
    }

    // Fails if: CampaignCanvasView.swift `setup` stops gating its end-of-item observer on `if loop`
    // (a non-looping card would restart), or drops `if autoplay { runtime.play(value) }`.
    @Test("an autoplaying, unmuted, non-looping card starts playing at full volume")
    func autoplayUnmutedOnce() async throws {
        let probe = Probe()
        let (sdk, _) = try await show(probe: probe) { props in
            props["autoplay"] = true
            props["muted"] = false
            props["loop"] = false
        }
        defer { sdk.tearDown() }

        #expect(probe.plays == 1)
        #expect(probe.players.first?.isMuted == false)
        try playToEnd(probe)
        #expect(probe.restarts == 0, "it does not loop")
    }

    // Fails if: CampaignCanvasView.swift `CanvasVideoRenderer` stops mapping `fit == "contain"` to
    // `.resizeAspect` (cover would crop a contained video, or contain letterbox a covered one).
    @Test("contain shows the whole video; cover fills the frame and crops what spills over",
          arguments: [("contain", AVLayerVideoGravity.resizeAspect),
                      ("cover", AVLayerVideoGravity.resizeAspectFill)])
    func fit(_ fit: String, gravity: AVLayerVideoGravity) async throws {
        let probe = Probe()
        let (sdk, _) = try await show(probe: probe) { $0["fit"] = fit }
        defer { sdk.tearDown() }

        let controller = try #require(Self.playerController(in: sdk.window?.rootViewController))
        #expect(controller.videoGravity == gravity)
        #expect(controller.showsPlaybackControls, "the fixture asks for controls")
    }

    /// Presents a plain screen over the app, as the app opening its cart would, then takes it away.
    private func cover(_ sdk: SdkHarness) throws {
        let root = try #require(sdk.window?.rootViewController)
        let cart = UIHostingController(rootView: Text("Cart"))
        cart.modalPresentationStyle = .fullScreen
        root.present(cart, animated: false)
        TouchSynthesizer.drainRunLoop(for: 0.5)
    }

    private func uncover(_ sdk: SdkHarness) throws {
        let root = try #require(sdk.window?.rootViewController)
        root.dismiss(animated: false)
        TouchSynthesizer.drainRunLoop(for: 0.5)
    }

    // Fails if: CampaignCanvasView.swift `CanvasVideoRenderer` loses `.onDisappear { teardown() }`
    // (nothing pauses it behind the Cart) or `.onAppear { setup(url: url) }` (it stays silent after).
    @Test("pauses a playing video behind another screen, and plays it again once uncovered")
    func coveredPausesAndResumes() async throws {
        let probe = Probe()
        let (sdk, _) = try await show(probe: probe) { $0["autoplay"] = true }
        defer { sdk.tearDown() }
        #expect(probe.plays == 1)

        try cover(sdk)
        #expect(sdk.isShowing("Cart"))
        // SwiftUI sends `onDisappear` once UIKit has taken the covered screen out of the window,
        // which can land after the cover's own run-loop turn.
        try await sdk.waitUntil("silent behind the Cart") { probe.pauses >= 1 }

        let playsBefore = probe.plays
        try uncover(sdk)
        try await sdk.waitUntil("it plays again") { probe.plays > playsBefore }
    }

    // Fails if: CampaignCanvasView.swift `setup` plays without `if autoplay`.
    @Test("leaves a card that is not set to autoplay alone when it is uncovered")
    func coveredNonAutoplayStaysPaused() async throws {
        let probe = Probe()
        let (sdk, _) = try await show(probe: probe)
        defer { sdk.tearDown() }

        try cover(sdk)
        try uncover(sdk)
        // Uncovered, the card builds its player again; an unwanted play would land with it.
        try await sdk.waitUntil("the card's player is made again") { probe.players.count >= 2 }
        try await sdk.settle(0.3)

        #expect(probe.plays == 0)
    }

    /// Flutter replaces a video it cannot open with a "Couldn't load video" surface. iOS keeps the
    /// card and its black player frame and reports the failure to the health timeline
    /// (`media_load_failed`); the missing error surface is the known gap.
    // Fails if: CampaignCanvasView.swift `setup` stops observing the item's `status` and calling
    // `reportMediaLoadFailed(.video, …)` on `.failed`.
    @Test("a video that cannot be opened keeps the card and reports the failure")
    func brokenVideoDegrades() async throws {
        // A file that is there but is not a video: AVFoundation fails to parse it.
        let (sdk, _) = try await show(probe: nil) { props in
            var source = props["source"] as? [String: Any] ?? [:]
            source["url"] = (source["url"] as? String ?? "")
                .replacingOccurrences(of: "big-buck-bunny.mp4", with: "testkit-badge.svg")
            props["source"] = source
        }
        defer { sdk.tearDown() }
        let key = "test_canvas_video_player"

        try await sdk.waitUntil("the failure is reported", timeout: 5) {
            !sdk.records(key, reason: TimelineReason.mediaLoadFailed).isEmpty
        }
        #expect(sdk.isShowing("Embedded Video Player"), "the rest of the card stays")
        withKnownIssue("iOS shows no error surface for a video it cannot open") {
            #expect(sdk.isShowing("Couldn't load video"))
        }
    }

    private static func playerController(in controller: UIViewController?) -> AVPlayerViewController? {
        guard let controller else { return nil }
        if let player = controller as? AVPlayerViewController { return player }
        for child in controller.children {
            if let found = playerController(in: child) { return found }
        }
        return playerController(in: controller.presentedViewController)
    }
}
}
