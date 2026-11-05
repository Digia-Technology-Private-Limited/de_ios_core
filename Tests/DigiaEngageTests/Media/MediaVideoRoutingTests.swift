import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// T3: each legacy video surface plays through `MediaVideo`. The proof is the request log: only
// `MediaVideo`'s range-cache loader reads through `MediaServices`' video session, which the fake
// origin is routed to; a surface's own `AVPlayerItem(url:)` never reaches it.

// OD-15: every `MediaVideo` borrows its player from the pool, a node with no key of its own
// borrowing under a key it makes up.

@MainActor
private final class CanvasDarkModel: ObservableObject {
    @Published var isDark = false
}

private struct CanvasVideoHost: View {
    @ObservedObject var model: CanvasDarkModel
    let light: URL
    let dark: URL

    var body: some View {
        let widget = CampaignCanvasWidget.video(
            box: .none,
            source: CampaignCanvasMediaSource(url: light.absoluteString, darkUrl: dark.absoluteString, placeholder: nil),
            autoplay: false, loop: false, muted: true, showControls: false, fit: "cover")
        var stage = CampaignCanvasStage(
            canvas: CampaignCanvas(
                version: 2, width: 240, height: 120, background: .solid(.literal("#FF000000")),
                children: [.widget(id: "video", rect: CampaignCanvasRect(x: 0, y: 0, width: 240, height: 120), widget: widget)]),
            authoredCornerRadius: 0, isDark: model.isDark, showBackground: true, onAction: { _ in })
        stage.animateWidgetsOnAppear = false
        return stage
    }
}

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

    // Guards `key ?? ownKey` in `MediaVideoPlayback.open` and the `own` discard in `close` (OD-15):
    // a nudge has no node key, so it borrows under one of its own and its player is destroyed, not
    // parked, when the nudge goes.
    @Test("a nudge video takes a pool player under its own key and destroys it on unmount")
    func nudgeVideoTakesAPoolPlayerAndDestroysItOnUnmount() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("nudge-pool.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let pool = MediaServices.current.videoPool
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
        #expect(await waitUntilMedia { pool.heldKeys.count == 1 })
        #expect(pool.heldKeys.allSatisfy { $0.hasPrefix("media-video-") })

        ComponentTestHost.unmount(window)
        #expect(await waitUntilMedia { pool.heldKeys.isEmpty })
        #expect(pool.livePlayerCount == 0, "destroyed, not kept idle")
    }

    // Guards `playerKey` in `CanvasVideoRenderer` and the `.environment(\.digiaCanvasChildId, id)`
    // in `CanvasChildView` (OD-15): the key is the campaign plus the canvas child's id, so a
    // remount gets its player back.
    @Test("a canvas video takes a pool player under its canvas key and gives it back on unmount")
    func canvasVideoTakesAPoolPlayerUnderItsCanvasKey() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let light = MediaOrigin.url("canvas-pool-light.mp4")
        let dark = MediaOrigin.url("canvas-pool-dark.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: light)
        let pool = MediaServices.current.videoPool

        let window = MediaStage.mount(CanvasVideoHost(model: CanvasDarkModel(), light: light, dark: dark))
        let key = "canvas-video-\(MediaStage.campaign)-video"
        #expect(await waitUntilMedia { pool.heldKeys == [key] })

        ComponentTestHost.unmount(window)
        #expect(await waitUntilMedia { pool.heldKeys.isEmpty })
        #expect(pool.livePlayerCount == 1, "kept for a remount under the same key")
    }

    // Guards the `reused.url != url` re-point in `VideoPlayerPool.borrow` as the canvas reaches
    // it (N5): a dark-mode toggle changes the URL under the same canvas key; the one player plays
    // the new URL and nothing is left behind.
    @Test("a canvas video's URL toggle re-points the player under its key and leaves nothing behind")
    func canvasVideoURLToggleRepointsUnderItsKey() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let light = MediaOrigin.url("canvas-toggle-light.mp4")
        let dark = MediaOrigin.url("canvas-toggle-dark.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: light)
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: dark)
        let pool = MediaServices.current.videoPool
        let model = CanvasDarkModel()
        let key = "canvas-video-\(MediaStage.campaign)-video"

        let window = MediaStage.mount(CanvasVideoHost(model: model, light: light, dark: dark))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: light).isEmpty })
        let player = try #require(pool.heldPlayer(for: key))

        model.isDark = true
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: dark).isEmpty })

        #expect(pool.heldKeys == [key])
        #expect(pool.heldPlayer(for: key) === player, "the same player, re-pointed")
        #expect(pool.livePlayerCount == 1, "no leftover player")
    }
}
}
