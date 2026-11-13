import Foundation
import Testing

@testable import DigiaEngage

// The canvas video's own logic: hit testing. Playback is `MediaVideo`'s (T3), so
// autoplay, loop, mute, teardown and failure are covered by the MediaVideo suites.

@Suite("Canvas video renderer", .tags(.canvas, .unit, .media))
struct CanvasVideoRendererTests {
    // No mode: model logic only (`isHitTestable`); nothing is mounted and no runtime is used.
    @Test("video consumes touches only when native controls are visible")
    func hitTestingMatchesControls() {
        let interactive = canvasChild(video: videoWidget(showControls: true))
        let decorative = canvasChild(video: videoWidget(showControls: false))

        #expect(interactive.isHitTestable)
        #expect(!decorative.isHitTestable)
    }

    private func videoWidget(
        url: String = "https://example.invalid/video.mp4",
        darkURL: String? = nil,
        autoplay: Bool = false,
        loop: Bool = false,
        muted: Bool = false,
        showControls: Bool = true,
        fit: String = "cover"
    ) -> CampaignCanvasWidget {
        .video(
            box: .none,
            source: CampaignCanvasMediaSource(url: url, darkUrl: darkURL, placeholder: nil),
            autoplay: autoplay,
            loop: loop,
            muted: muted,
            showControls: showControls,
            fit: fit
        )
    }

    private func canvasChild(video: CampaignCanvasWidget) -> CampaignCanvasChild {
        .widget(
            id: "video",
            rect: CampaignCanvasRect(x: 0, y: 0, width: 320, height: 180),
            widget: video
        )
    }
}
