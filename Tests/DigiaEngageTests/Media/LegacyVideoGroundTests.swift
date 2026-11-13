import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// OD-16: the letterbox after the first frame is black by default, on every surface. `MediaVideo`'s
// #1A1A1A is only the loading ground before the first frame.

extension RenderedUITests {
@MainActor
@Suite("Legacy video ground", .serialized, .tags(.media, .component, .canvas))
struct LegacyVideoGroundTests {
    // Fails if `MediaVideo`'s `groundAfterFirstFrame` default (`.black`) changes, or if
    // `MediaVideo.body` draws `mediaVideoBackdrop` after the first frame instead of
    // `groundAfterFirstFrame`.
    @Test("a contain video letterboxes on black after the first frame by default")
    func canvasLetterboxIsBlackAfterTheFirstFrame() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        // movie.mp4 is 4:3, so in the 2:1 box it pillarboxes: 40 pt each side.
        let video = MediaOrigin.url("letterbox.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let widget = CampaignCanvasWidget.video(
            box: .none,
            source: CampaignCanvasMediaSource(url: video.absoluteString, darkUrl: nil, placeholder: nil),
            autoplay: false, loop: false, muted: true, showControls: false, fit: "contain")
        // A white canvas, so a ground that is not drawn shows as white, not as black.
        var stage = CampaignCanvasStage(
            canvas: CampaignCanvas(
                version: 2, width: 240, height: 120, background: .solid(.literal("#FFFFFFFF")),
                children: [.widget(id: "video", rect: CampaignCanvasRect(x: 0, y: 0, width: 240, height: 120), widget: widget)]),
            authoredCornerRadius: 0, isDark: false, showBackground: true, onAction: { _ in })
        stage.animateWidgetsOnAppear = false

        let window = MediaStage.mount(stage)
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia {
            let layers = Self.playerLayers(in: window)
            return !layers.isEmpty && layers.allSatisfy { $0.isReadyForDisplay }
        })
        // `MediaVideo` notes the frame on the main queue, then SwiftUI redraws.
        try await Task.sleep(nanoseconds: 200_000_000)
        ComponentTestHost.drainRunLoop(for: 0.2)

        let image = ComponentTestHost.settledImage(of: window)
        let box = CGRect(
            x: (image.size.width - MediaStage.size.width) / 2, y: (image.size.height - MediaStage.size.height) / 2,
            width: MediaStage.size.width, height: MediaStage.size.height)
        let pillar = try #require(pixelColor(
            of: image, atX: Int((box.minX + 10) * image.scale), y: Int(box.midY * image.scale)))
        #expect(colorsNearly(pillar, .black), "letterbox is \(pillar), not black")
    }

    private static func playerLayers(in view: UIView) -> [AVPlayerLayer] {
        // A video view draws through the engine player's layer, a sublayer of its own.
        let own = [view.layer] + (view.layer.sublayers ?? [])
        return own.compactMap { $0 as? AVPlayerLayer } + view.subviews.flatMap { playerLayers(in: $0) }
    }
}
}
