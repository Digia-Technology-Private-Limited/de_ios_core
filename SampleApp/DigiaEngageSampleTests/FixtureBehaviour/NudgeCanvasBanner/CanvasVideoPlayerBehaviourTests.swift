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
