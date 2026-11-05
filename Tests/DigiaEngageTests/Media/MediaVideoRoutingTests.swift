import AVFoundation
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

/// A canvas of 120 x 120 video widgets side by side, each with its own URL; `variables` resolve
/// `{{...}}` in them.
private func canvasVideoStage(
    urls: [String], loop: Bool = false, autoplay: Bool = false, variables: VariableContext? = nil
) -> some View {
    var stage = CampaignCanvasStage(
        canvas: CampaignCanvas(
            version: 2, width: 240, height: 120, background: .solid(.literal("#FF000000")),
            children: urls.enumerated().map { index, url in
                .widget(
                    id: "video-\(index)",
                    rect: CampaignCanvasRect(x: CGFloat(index) * 120, y: 0, width: 120, height: 120),
                    widget: .video(
                        box: .none,
                        source: CampaignCanvasMediaSource(url: url, darkUrl: nil, placeholder: nil),
                        autoplay: autoplay, loop: loop, muted: true, showControls: false, fit: "cover"))
            }),
        authoredCornerRadius: 0, isDark: false, showBackground: true, onAction: { _ in })
    stage.animateWidgetsOnAppear = false
    return stage.environment(\.digiaVariables, variables)
}

extension RenderedUITests {
@MainActor
@Suite("MediaVideo routing", .serialized, .tags(.media, .component))
struct MediaVideoRoutingTests {
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

    // Guards `interpolate(...)` in `CanvasVideoRenderer.url`: a `{{variable}}` in the URL is
    // resolved before the player is built, so the resolved URL is fetched and nothing is reported.
    @Test("a canvas video's URL variables resolve before its player is built")
    func canvasVideoResolvesItsURLVariables() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let recorder = HealthRecorder()
        let resolved = MediaOrigin.url("resolved-clip.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: resolved)
        let template = "https://\(MediaOrigin.host)/\(resolved.pathComponents[1])/{{clip}}.mp4"

        let window = MediaStage.mount(canvasVideoStage(
            urls: [template],
            variables: VariableContext(values: ["clip": "resolved-clip"], types: ["clip": "string"])))
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !MediaOrigin.requests(for: resolved).isEmpty })
        #expect(recorder.all.isEmpty, "not reported as an unusable URL")
    }

    // Guards `if !url.isEmpty` in `CanvasVideoRenderer.body`: a canvas video with no URL builds no
    // player and reports nothing (an empty `MediaVideo` would report `invalid_url`).
    @Test("a canvas video with an empty URL builds no player and reports nothing")
    func canvasVideoWithAnEmptyURLBuildsNoPlayer() async {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let recorder = HealthRecorder()
        let pool = MediaServices.current.videoPool

        let window = MediaStage.mount(canvasVideoStage(urls: [""]))
        defer { ComponentTestHost.unmount(window) }
        _ = await waitUntilMedia(timeout: 0.5) { false }

        #expect(recorder.all.isEmpty)
        #expect(pool.livePlayerCount == 0)
        #expect(MediaOrigin.totalRequestCount() == 0)
    }

    // Guards `NotificationCenter ... object: item` in `MediaVideoPlayback.watch` and the `loop`
    // branch of `noteEnded`: a looping video that ends starts over, and its neighbour, playing the
    // same kind of item, is not restarted with it.
    @Test("a looping video restarts only the item that ended", arguments: ["canvas", "nudge"])
    func loopRestartsOnlyTheItemThatEnded(surface: String) async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let urls = [MediaOrigin.url("loop-a.mp4"), MediaOrigin.url("loop-b.mp4")]
        for url in urls { MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: url) }
        let pool = MediaServices.current.videoPool
        let window: UIWindow
        if surface == "canvas" {
            window = MediaStage.mount(canvasVideoStage(urls: urls.map(\.absoluteString), loop: true, autoplay: true))
        } else {
            let column = try #require(NudgeParser().parse([
                "layout": [
                    "type": "digia/column",
                    "children": urls.map { url in
                        [
                            "type": "digia/videoPlayer",
                            "props": ["url": url.absoluteString, "autoPlay": true, "looping": true, "height": 60],
                        ] as [String: Any]
                    },
                ],
            ]))
            window = MediaStage.mount(NudgeColumnContent(column: column, onDismiss: {}))
        }
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { pool.heldKeys.count == 2 })
        let players = pool.heldKeys.sorted().compactMap { pool.heldPlayer(for: $0) }
        let (ending, other) = (players[0], players[1])
        #expect(await waitUntilMedia { players.allSatisfy { $0.currentTime().seconds > 0.3 } }, "both are playing")
        // Exact, so the neighbour sits mid-video rather than snapping to the last keyframe, which is
        // near the end.
        #expect(await other.seek(
            to: CMTime(seconds: 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero))
        let duration = try #require(ending.currentItem?.duration.seconds)
        #expect(await ending.seek(to: CMTime(seconds: duration - 0.4, preferredTimescale: 600)))

        #expect(await waitUntilMedia(timeout: 6) { ending.currentTime().seconds < 2 && ending.rate > 0 }, "the ended one started over")
        #expect(other.currentTime().seconds >= 4, "its neighbour carried on from 4 s: \(other.currentTime().seconds)")
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
