import Foundation
@testable import DigiaEngage
import Testing

@Suite("Digia video streaming")
struct DigiaVideoStreamingTests {
    @Test("derives the AVFoundation MIME override from the video extension", arguments: [
        ("https://cdn.example.com/story.mp4?token=abc", "video/mp4"),
        ("https://cdn.example.com/story.MOV", "video/quicktime"),
        ("https://cdn.example.com/story.m4v", "video/x-m4v"),
        ("https://cdn.example.com/story", "video/mp4"),
    ])
    func derivesMIMEType(urlString: String, expected: String) throws {
        let url = try #require(URL(string: urlString))

        #expect(DigiaVideoStreaming.mimeType(for: url) == expected)
    }

    @Test("keeps AVFoundation on the original HTTP URL on iOS 17 and newer")
    func usesNativeHTTPTransportWhenAvailable() throws {
        guard #available(iOS 17, *) else { return }
        let url = try #require(URL(string: "https://cdn.example.com/story.mp4"))

        let asset = DigiaVideoStreaming.makeAsset(for: url)

        #expect(asset.url == url)
    }

    @Test("parses an HTTP partial-content range")
    func parsesContentRange() throws {
        let url = try #require(URL(string: "https://cdn.example.com/story.mp4"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 100-199/1000"]
        ))

        let range = try #require(DigiaStreamingResourceLoaderDelegate.contentRange(from: response))

        #expect(range.start == 100)
        #expect(range.total == 1000)
    }

    @Test("returns only the requested bytes from a range response")
    func slicesRangePayload() throws {
        let responseBytes = Data([100, 101, 102, 103, 104, 105, 106, 107, 108, 109])

        let payload = try #require(DigiaStreamingResourceLoaderDelegate.payload(
            from: responseBytes,
            responseStart: 100,
            requestedStart: 103,
            requestedLength: 4
        ))

        #expect(payload == Data([103, 104, 105, 106]))
    }
}
