import Foundation
import Testing

@testable import DigiaEngage

/// Guards the single-file skin cache: the production lines are
/// `directoryName`/`safeSkinId`, the hit/miss checks, and the download
/// validation. Network runs through a stub `URLProtocol`, never the wire.
@Suite("Game skin file cache", .serialized, .tags(.unit, .game))
struct SkinFileCacheTests {
    private func makeCache(
        session: URLSession? = nil, caches: URL? = nil
    ) -> (SkinFileCache, URL) {
        let directory = caches ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("test-skins-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSkinURLProtocol.self]
        return (
            SkinFileCache(cachesDirectory: directory, session: session ?? URLSession(configuration: configuration)),
            directory)
    }

    @Test("cache directory joins sanitized skin id and version")
    func cacheKey() {
        // Guards directoryName: versions stay apart, unsafe ids stay in-root.
        #expect(SkinFileCache.directoryName(skinId: "wheel", version: 3) == "wheel/3")
        #expect(SkinFileCache.directoryName(skinId: "wheel", version: 4) == "wheel/4")
        #expect(SkinFileCache.directoryName(skinId: "../evil", version: 1) == ".._evil/1")
        #expect(SkinFileCache.safeSkinId("") == "_")
    }

    @Test("misses read nil, stores hit")
    func storeAndHit() throws {
        let (cache, _) = makeCache()

        #expect(cache.cachedFile(skinId: "wheel", version: 3) == nil)
        let data = Data("<html></html>".utf8)
        let file = try cache.store(skinId: "wheel", version: 3, data: data)

        // Guards the existence check in cachedFile; versions stay isolated.
        #expect(cache.cachedFile(skinId: "wheel", version: 3) == file)
        #expect(try Data(contentsOf: file) == data)
        #expect(cache.cachedFile(skinId: "wheel", version: 4) == nil)
        #expect(cache.cachedFile(skinId: "chest", version: 3) == nil)
    }

    @Test("download stores the single file and does not re-download")
    func downloadCaches() async throws {
        StubSkinURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://cdn.example.com/s/wheel/3/index.html")!,
                statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data("<html>v3</html>".utf8))
        }
        defer { StubSkinURLProtocol.handler = nil }
        let (cache, _) = makeCache()
        var downloads = 0
        let counting = StubSkinURLProtocol.handler!
        StubSkinURLProtocol.handler = { request in
            downloads += 1
            return try counting(request)
        }

        let first = try await cache.download(
            bundleUrl: "https://cdn.example.com/s/wheel/3/index.html", skinId: "wheel", version: 3)
        let second = try await cache.download(
            bundleUrl: "https://cdn.example.com/s/wheel/3/index.html", skinId: "wheel", version: 3)

        #expect(first == second)
        #expect(try String(data: Data(contentsOf: first), encoding: .utf8) == "<html>v3</html>")
        // Guards the cached-first check in download.
        #expect(downloads == 1)
    }

    @Test("bad URLs, statuses and bodies throw")
    func downloadFailures() async {
        let (cache, _) = makeCache()

        // Guards the scheme check: only http(s) downloads.
        await #expect(throws: SkinFileCacheError.self) {
            try await cache.download(bundleUrl: "not a url %%", skinId: "wheel", version: 1)
        }

        StubSkinURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data())
        }
        defer { StubSkinURLProtocol.handler = nil }
        // Guards the status check.
        await #expect(throws: SkinFileCacheError.self) {
            try await cache.download(
                bundleUrl: "https://cdn.example.com/s/wheel/3/index.html", skinId: "wheel", version: 2)
        }
        #expect(cache.cachedFile(skinId: "wheel", version: 2) == nil)
    }

    @Test("prefetch skips cached entries and drops failures")
    func prefetchDropsFailures() async {
        StubSkinURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data("<html></html>".utf8))
        }
        defer { StubSkinURLProtocol.handler = nil }
        let (cache, _) = makeCache()

        await cache.prefetch([
            (bundleUrl: "https://cdn.example.com/s/wheel/3/index.html", skinId: "wheel", version: 3),
            (bundleUrl: "broken", skinId: "broken", version: 1),
        ])

        #expect(cache.cachedFile(skinId: "wheel", version: 3) != nil)
        #expect(cache.cachedFile(skinId: "broken", version: 1) == nil)
    }
}

/// Stubs the wire for `SkinFileCache` download tests.
private final class StubSkinURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
