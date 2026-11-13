import AVKit
import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// What a canvas card's embedded video does, driven from the shared fixture
/// `canvas/canvas_video_player`: a muted, looping, non-autoplaying player with controls, fitted to
/// contain. The fixture is served by the scripted bundle, delivered the way a CEP does and drawn by
/// the app's own `DigiaSlot`. Nothing is replaced: the card draws `MediaVideo`, and the tests read
/// the real `AVPlayer` from its `AVPlayerViewController`. A test that changes how the video is authored edits that
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

    /// Delivers the fixture, with [author] changing its video's props. With [waitForPlayer], waits
    /// until the card has its player. Returns the harness and the authored video URL.
    private func show(
        waitForPlayer: Bool = true, author: (inout [String: Any]) -> Void = { _ in }
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
            DigiaSlot("home_banner") { EmptyView() }
        }
        try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntil("the card is on screen") { sdk.isShowing("Embedded Video Player") }
        if waitForPlayer {
            try await sdk.waitUntil("the card's player is made") { Self.player(sdk) != nil }
        }
        return (sdk, url)
    }

    /// The player the card's `AVPlayerViewController` shows, if it has one.
    private static func player(_ sdk: SdkHarness) -> AVPlayer? {
        playerController(in: sdk.window?.rootViewController)?.player
    }

    /// Pauses the card's player and ends its item, as AVFoundation does when the video reaches its
    /// end; a looping card plays again.
    private func playToEnd(_ player: AVPlayer) throws {
        player.pause()
        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime, object: try #require(player.currentItem))
        TouchSynthesizer.drainRunLoop(for: 0.1)
    }

    // Fails if: MediaVideo.swift `MediaVideoPlayback.open` drops `player.isMuted = muted`.
    @Test("the authored mute, loop and autoplay reach the player: this card opens silent, looping and waiting to be played")
    func authoredPlaybackReachesThePlayer() async throws {
        let (sdk, url) = try await show()
        defer { sdk.tearDown() }

        let player = try #require(Self.player(sdk))
        #expect((player.currentItem?.asset as? AVURLAsset)?.url.absoluteString == url)
        #expect(player.isMuted == true)
        #expect(player.rate == 0, "autoplay is off")
        try playToEnd(player)
        #expect(player.rate > 0, "it loops")
    }

    // Fails if: MediaVideo.swift `noteEnded` stops gating its restart on `if loop` (a non-looping
    // card would play again), or the open stops playing when `autoplay` is on.
    @Test("an autoplaying, unmuted, non-looping card starts playing at full volume")
    func autoplayUnmutedOnce() async throws {
        let (sdk, _) = try await show { props in
            props["autoplay"] = true
            props["muted"] = false
            props["loop"] = false
        }
        defer { sdk.tearDown() }

        let player = try #require(Self.player(sdk))
        #expect(player.rate > 0)
        #expect(player.isMuted == false)
        try playToEnd(player)
        #expect(player.rate == 0, "it does not loop")
    }

    // Fails if: MediaFit.swift stops mapping `.contain` to `.resizeAspect` (cover would crop a contained video, or contain letterbox a covered one).
    @Test("contain shows the whole video; cover fills the frame and crops what spills over",
          arguments: [("contain", AVLayerVideoGravity.resizeAspect),
                      ("cover", AVLayerVideoGravity.resizeAspectFill)])
    func fit(_ fit: String, gravity: AVLayerVideoGravity) async throws {
        let (sdk, _) = try await show { $0["fit"] = fit }
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

    // Fails if: MediaVideo.swift loses `.onDisappear { playback.close() }` (nothing pauses it
    // behind the Cart) or `.onAppear { open(…) }` (it stays silent after).
    @Test("pauses a playing video behind another screen, and plays it again once uncovered")
    func coveredPausesAndResumes() async throws {
        let (sdk, _) = try await show { $0["autoplay"] = true }
        defer { sdk.tearDown() }
        let first = try #require(Self.player(sdk))
        #expect(first.rate > 0)

        try cover(sdk)
        #expect(sdk.isShowing("Cart"))
        // SwiftUI sends `onDisappear` once UIKit has taken the covered screen out of the window,
        // which can land after the cover's own run-loop turn.
        try await sdk.waitUntil("silent behind the Cart") { first.rate == 0 }

        try uncover(sdk)
        try await sdk.waitUntil("it plays again") { (Self.player(sdk)?.rate ?? 0) > 0 }
    }

    // Fails if: MediaVideo.swift `MediaVideoPlayback.open` plays without `if autoplay`.
    @Test("leaves a card that is not set to autoplay alone when it is uncovered")
    func coveredNonAutoplayStaysPaused() async throws {
        let (sdk, _) = try await show()
        defer { sdk.tearDown() }

        try cover(sdk)
        try uncover(sdk)
        try await sdk.waitUntil("the card's player is back") { Self.player(sdk) != nil }
        try await sdk.settle(0.3)

        #expect(Self.player(sdk)?.rate == 0)
    }

    /// Flutter replaces a video it cannot open with a "Couldn't load video" surface. iOS keeps the
    /// card, shows `MediaVideo`'s "Video failed" box and reports the failure to the health timeline
    /// (`media_load_failed`); Flutter's own label is the known gap.
    // Fails if: MediaVideo.swift `watch` stops observing the item's `status` and failing on
    // `.failed`.
    @Test("a video that cannot be opened keeps the card and reports the failure")
    func brokenVideoDegrades() async throws {
        // A file that is there but is not a video: AVFoundation fails to parse it.
        let (sdk, _) = try await show(waitForPlayer: false) { props in
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
