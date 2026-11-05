import Foundation
import Testing

@testable import DigiaEngage

// The canvas video's own logic: the parser and hit testing. Playback is `MediaVideo`'s (T3), so
// autoplay, loop, mute, teardown and failure are covered by the MediaVideo suites.

@Suite("Canvas video renderer", .tags(.canvas, .unit, .media))
struct CanvasVideoRendererTests {
    // No mode: parser only, no player runtime.
    @Test("video parser preserves every authored playback option")
    func parserPreservesPlaybackOptions() throws {
        let widget = try parsedVideo([
            "source": ["url": "light.mp4", "darkUrl": "dark.mp4"],
            "autoplay": true,
            "loop": true,
            "muted": true,
            "showControls": false,
            "fit": "contain",
        ])

        guard
            case .video(_, let source, let autoplay, let loop, let muted, let controls, let fit) =
                widget
        else {
            Issue.record("Expected a parsed video widget")
            return
        }
        #expect(source.url == "light.mp4")
        #expect(source.darkUrl == "dark.mp4")
        #expect(autoplay)
        #expect(loop)
        #expect(muted)
        #expect(!controls)
        #expect(fit == "contain")
    }

    // No mode: parser only, no player runtime.
    @Test("video parser uses safe defaults and normalizes unsupported fit values")
    func parserDefaults() throws {
        guard
            case .video(_, let source, let autoplay, let loop, let muted, let controls, let fit) =
                try parsedVideo(["fit": "fill"])
        else {
            Issue.record("Expected a parsed video widget")
            return
        }
        #expect(source.url.isEmpty)
        #expect(!autoplay)
        #expect(!loop)
        #expect(!muted)
        #expect(controls)
        #expect(fit == "cover")
    }

    // No mode: model logic only (`isHitTestable`); nothing is mounted and no runtime is used.
    @Test("video consumes touches only when native controls are visible")
    func hitTestingMatchesControls() {
        let interactive = canvasChild(video: videoWidget(showControls: true))
        let decorative = canvasChild(video: videoWidget(showControls: false))

        #expect(interactive.isHitTestable)
        #expect(!decorative.isHitTestable)
    }

    private func parsedVideo(_ props: [String: Any]) throws -> CampaignCanvasWidget {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 320,
            "canvasHeight": 180,
            "children": [
                [
                    "kind": "widget",
                    "id": "video",
                    "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
                    "widget": ["type": "digia/videoPlayer", "props": props],
                ]
            ],
        ])
        guard case .widget(_, _, let widget) = canvas.children.first else {
            throw VideoTestError.missingWidget
        }
        return widget
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

private enum VideoTestError: Error {
    case missingWidget
}
