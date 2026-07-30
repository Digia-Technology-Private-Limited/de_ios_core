import Foundation
@testable import DigiaEngage
import Testing

@Suite("Nudge video aspect ratio")
struct NudgeVideoAspectRatioTests {
    @Test("positive ratio parses and clears stale fixed height")
    func parsesAspectRatio() throws {
        let video = try #require(parseVideo(
            props: [
                "url": "https://cdn.example.com/video.mp4",
                "aspectRatio": 0.5625,
                "height": 640,
            ],
            containerProps: ["style": ["height": "320"]]
        ))

        #expect(video.aspectRatio == 0.5625)
        #expect(video.height == 640)
        #expect(video.box.fixedHeight == nil)
    }

    @Test("non-positive ratio preserves fixed-height behavior")
    func preservesFixedHeightFallback() throws {
        let video = try #require(parseVideo(
            props: ["aspectRatio": -1, "height": 280],
            containerProps: ["style": ["height": "300"]]
        ))

        #expect(video.aspectRatio == 0)
        #expect(video.height == 280)
        #expect(video.box.fixedHeight == 300)
    }

    private func parseVideo(
        props: [String: Any],
        containerProps: [String: Any]? = nil
    ) -> NudgeVideo? {
        var node: [String: Any] = [
            "type": "digia/videoPlayer",
            "props": props,
        ]
        if let containerProps {
            node["containerProps"] = containerProps
        }
        let column = NudgeParser().parse([
            "layout": [
                "type": "digia/column",
                "children": [node],
            ],
        ])
        guard let first = column?.children.first, case .video(let video) = first else {
            return nil
        }
        return video
    }
}
