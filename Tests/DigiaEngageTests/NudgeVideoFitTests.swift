import AVFoundation
import Testing
@testable import DigiaEngage

@Suite("Nudge video fit")
struct NudgeVideoFitTests {
    @Test("defaults to cover and parses contain")
    func parsesSupportedFits() throws {
        #expect(try video().boxFit == .cover)
        #expect(try video("cover").boxFit == .cover)
        #expect(try video("contain").boxFit == .contain)
    }

    @Test("normalizes stretch and unknown values to cover")
    func normalizesUnsupportedFits() throws {
        #expect(try video("fill").boxFit == .cover)
        #expect(try video("future-fit").boxFit == .cover)
    }

    @Test("maps fits to player video gravity")
    func mapsVideoGravity() {
        #expect(NudgeVideoFit.cover.videoGravity == .resizeAspectFill)
        #expect(NudgeVideoFit.contain.videoGravity == .resizeAspect)
    }

    private func video(_ boxFit: String? = nil) throws -> NudgeVideo {
        var props: [String: Any] = [
            "url": "https://cdn.example.com/video.mp4"
        ]
        props["boxFit"] = boxFit
        let config = try #require(NudgeConfig.fromJson([
            "layout": [
                "type": "digia/column",
                "children": [
                    [
                        "type": "digia/videoPlayer",
                        "props": props
                    ]
                ]
            ]
        ]))
        guard case .video(let video) = config.layout.children.first else {
            Issue.record("Expected a video node")
            throw NudgeVideoFitTestError.missingVideo
        }
        return video
    }
}

private enum NudgeVideoFitTestError: Error {
    case missingVideo
}
