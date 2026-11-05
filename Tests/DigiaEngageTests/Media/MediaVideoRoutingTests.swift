import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// T3: each legacy video surface plays through `MediaVideo`. The proof is the request log: only
// `MediaVideo`'s range-cache loader reads through `MediaServices`' video session, which the fake
// origin is routed to; a surface's own `AVPlayerItem(url:)` never reaches it.

extension RenderedUITests {
@MainActor
@Suite("MediaVideo routing", .serialized, .tags(.media, .component))
struct MediaVideoRoutingTests {
    // Guards the `MediaVideo(...)` call in `NudgeVideoView.body`.
    @Test("a nudge video plays through MediaVideo")
    func nudgeVideoRoutesThroughMediaVideo() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("nudge.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let column = try #require(NudgeParser().parse([
            "layout": [
                "type": "digia/column",
                "children": [[
                    "type": "digia/videoPlayer",
                    "props": ["url": video.absoluteString, "autoPlay": false, "height": 120],
                ]],
            ],
        ]))

        let window = MediaStage.mount(NudgeColumnContent(column: column, onDismiss: {}))
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty })
    }

    // Guards the `MediaVideo(...)` call in `CanvasVideoRenderer.body`.
    @Test("a canvas video plays the theme's source through MediaVideo")
    func canvasVideoRoutesThroughMediaVideo() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        for isDark in [false, true] {
            let light = MediaOrigin.url("light.mp4")
            let dark = MediaOrigin.url("dark.mp4")
            MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: light)
            MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: dark)
            let widget = CampaignCanvasWidget.video(
                box: .none,
                source: CampaignCanvasMediaSource(url: light.absoluteString, darkUrl: dark.absoluteString, placeholder: nil),
                autoplay: false, loop: false, muted: true, showControls: true, fit: "cover")
            var stage = CampaignCanvasStage(
                canvas: CampaignCanvas(
                    version: 2, width: 240, height: 120, background: .solid(.literal("#FF000000")),
                    children: [.widget(id: "video", rect: CampaignCanvasRect(x: 0, y: 0, width: 240, height: 120), widget: widget)]),
                authoredCornerRadius: 0, isDark: isDark, showBackground: true, onAction: { _ in })
            stage.animateWidgetsOnAppear = false

            let window = MediaStage.mount(stage)
            let chosen = isDark ? dark : light
            let other = isDark ? light : dark
            #expect(await waitUntilMedia { !MediaOrigin.requests(for: chosen).isEmpty })
            #expect(MediaOrigin.requests(for: other).isEmpty)
            ComponentTestHost.unmount(window)
        }
    }
}
}
