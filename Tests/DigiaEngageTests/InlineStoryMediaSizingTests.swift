import AVFoundation
import SwiftUI
@testable import DigiaEngage
import Testing

@Suite("Inline story media sizing")
struct InlineStoryMediaSizingTests {
    @Test("accepts finite positive portrait square and landscape card ratios")
    func acceptsValidRatios() {
        for ratio in [9.0 / 16.0, 1.0, 16.0 / 9.0] {
            let config = StoryCardConfig.fromJson(["aspectRatio": ratio])
            #expect(config.aspectRatio == ratio)
            #expect(config.width == Double(config.height) * ratio)
        }
    }

    @Test("falls back for missing malformed non-finite and non-positive ratios")
    func rejectsInvalidRatios() {
        let values: [Any?] = [
            nil,
            "not-a-number",
            "NaN",
            "Infinity",
            Double.nan,
            Double.infinity,
            true,
            0,
            -1,
        ]
        for value in values {
            let json = value.map { ["aspectRatio": $0] } ?? [:]
            #expect(StoryCardConfig.fromJson(json).aspectRatio == 0.6)
        }
    }

    @Test("parses image and video fit capabilities")
    func parsesMediaFits() throws {
        #expect(try item(type: "image", fit: "fill").boxFit == .fill)
        #expect(try item(type: "image", fit: "contain").boxFit == .contain)
        #expect(try item(type: "video", fit: "contain").boxFit == .contain)
        #expect(try item(type: "video", fit: "fill").boxFit == .cover)
        #expect(try item(type: "video", fit: "future").boxFit == .cover)
        #expect(try item(type: "image", fit: "future").boxFit == .cover)
        #expect(try item(type: "image", fit: nil).boxFit == .cover)
    }

    @Test("maps image and video rendering modes")
    func mapsRenderingModes() {
        #expect(StoryMediaFit.cover.imageContentMode == .fill)
        #expect(StoryMediaFit.contain.imageContentMode == .fit)
        #expect(StoryMediaFit.fill.stretchesImage)
        #expect(StoryMediaFit.cover.videoGravity == .resizeAspectFill)
        #expect(StoryMediaFit.contain.videoGravity == .resizeAspect)
        #expect(StoryMediaFit.fill.videoGravity == .resizeAspectFill)
    }

    private func item(type: String, fit: String?) throws -> StoryItemConfig {
        var json: [String: Any] = [
            "type": type,
            "url": "https://cdn.example.com/story",
        ]
        if let fit {
            json["boxFit"] = fit
        }
        return try #require(StoryItemConfig.fromJson(json))
    }
}
