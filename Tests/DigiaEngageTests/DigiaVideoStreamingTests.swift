import Foundation
@testable import DigiaEngage
import Testing

@Suite("Digia video streaming")
struct DigiaVideoStreamingTests {
    @Test("persistent cache downloads one URL once across cache instances")
    func persistentCacheAvoidsDuplicateDownloads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        CountingVideoURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingVideoURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let remoteURL = try #require(URL(string: "https://cdn.example.com/story.mp4"))

        let firstCache = DigiaVideoFileCache(
            session: session,
            directory: directory,
            maxBytes: 1_024 * 1_024
        )
        async let firstRequest = firstCache.localURL(for: remoteURL)
        async let secondRequest = firstCache.localURL(for: remoteURL)
        async let thirdRequest = firstCache.localURL(for: remoteURL)
        let (firstURL, secondURL, thirdURL) = try await (
            firstRequest,
            secondRequest,
            thirdRequest
        )
        let nextLaunchCache = DigiaVideoFileCache(
            session: session,
            directory: directory,
            maxBytes: 1_024 * 1_024
        )
        let nextLaunchURL = try await nextLaunchCache.localURL(for: remoteURL)

        #expect(firstURL == secondURL)
        #expect(firstURL == thirdURL)
        #expect(firstURL == nextLaunchURL)
        #expect(try Data(contentsOf: firstURL) == CountingVideoURLProtocol.payload)
        #expect(CountingVideoURLProtocol.requestCount == 1)
    }

    @Test("prefetches four distinct videos in parallel")
    func prefetchesDistinctVideosInParallel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        ParallelVideoURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParallelVideoURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let urls = try (1...4).map { index in
            try #require(URL(string: "https://cdn.example.com/story-\(index).mp4"))
        }
        let cache = DigiaVideoFileCache(
            session: session,
            directory: directory,
            maxBytes: 1_024 * 1_024
        )

        await cache.prefetch(urls)

        #expect(ParallelVideoURLProtocol.requestCount == 4)
        #expect(ParallelVideoURLProtocol.maximumActiveRequests == 4)
    }

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

private final class CountingVideoURLProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data(repeating: 0x2A, count: 1_024)
    nonisolated(unsafe) private static var requests = 0
    private static let lock = NSLock()

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func reset() {
        lock.lock()
        requests = 0
        lock.unlock()
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(Self.payload.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ParallelVideoURLProtocol: URLProtocol, @unchecked Sendable {
    private static let payload = Data(repeating: 0x2A, count: 1_024)
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var activeRequests = 0
    nonisolated(unsafe) private static var maximumActive = 0
    private static let lock = NSLock()

    static var requestCount: Int {
        lock.withLock { requests }
    }

    static var maximumActiveRequests: Int {
        lock.withLock { maximumActive }
    }

    static func reset() {
        lock.withLock {
            requests = 0
            activeRequests = 0
            maximumActive = 0
        }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.requests += 1
            Self.activeRequests += 1
            Self.maximumActive = max(Self.maximumActive, Self.activeRequests)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(Self.payload.count)"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.payload)
            client?.urlProtocolDidFinishLoading(self)
            Self.lock.withLock { Self.activeRequests -= 1 }
        }
    }

    override func stopLoading() {}
}
