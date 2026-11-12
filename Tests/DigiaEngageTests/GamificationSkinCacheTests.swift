import Foundation
import Testing
import WebKit
@testable import DigiaEngage

/// URLProtocol stub owned by this suite, so parallel suites with their own
/// stubs can never see its handler. Tests in this suite run serialized.
final class GamiStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: StubResponse] = [:]
    nonisolated(unsafe) private static var failURLs: Set<String> = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var maxInFlight = 0
    nonisolated(unsafe) private static var latency: TimeInterval = 0

    static func reset(routes: [String: StubResponse] = [:], latency: TimeInterval = 0) {
        lock.withLock {
            self.routes = routes
            self.failURLs = []
            self.requests = []
            self.inFlight = 0
            self.maxInFlight = 0
            self.latency = latency
        }
    }

    static func setFailURLs(_ urls: Set<String>) {
        lock.withLock { failURLs = urls }
    }

    static var requestedURLs: [URL] {
        lock.withLock { requests.compactMap(\.url) }
    }

    static var peakInFlight: Int {
        lock.withLock { maxInFlight }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.requests.append(request)
            Self.inFlight += 1
            Self.maxInFlight = max(Self.maxInFlight, Self.inFlight)
        }
        let wait = Self.lock.withLock { Self.latency }
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        defer { Self.lock.withLock { Self.inFlight -= 1 } }
        let key = request.url?.absoluteString ?? ""
        let shouldFail = Self.lock.withLock { Self.failURLs.contains(key) }
        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let stub = Self.lock.withLock({ Self.routes[key] }) else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A `WKURLSchemeTask` double capturing what the scheme handler serves.
/// Lock-guarded: the CDN fallback delivers on a URLSession thread while the
/// test polls on the main actor.
final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private let lock = NSLock()
    private var _response: URLResponse?
    private var _receivedData = Data()
    private var _finished = false
    private var _failure: (any Error)?

    init(url: URL) {
        self.request = URLRequest(url: url)
    }

    var response: URLResponse? { lock.withLock { _response } }
    var receivedData: Data { lock.withLock { _receivedData } }
    var finished: Bool { lock.withLock { _finished } }
    var failure: (any Error)? { lock.withLock { _failure } }

    func didReceive(_ response: URLResponse) { lock.withLock { _response = response } }
    func didReceive(_ data: Data) { lock.withLock { _receivedData.append(data) } }
    func didFinish() { lock.withLock { _finished = true } }
    func didFailWithError(_ error: Error) { lock.withLock { _failure = error } }
}

@Suite("Gamification skin cache", .tags(.unit, .gami), .serialized)
struct GamificationSkinCacheTests {

    private struct StubbedBundle {
        let base: URL
        var bundleUrl: URL { base.appendingPathComponent("index.html") }
        let files: [(path: String, body: Data)]
        var routes: [String: GamiStubURLProtocol.StubResponse] {
            var routes: [String: GamiStubURLProtocol.StubResponse] = [:]
            let manifest = SkinBundleManifest(files: files.map {
                SkinBundleManifest.Entry(path: $0.path, size: $0.body.count)
            })
            routes[base.appendingPathComponent("files.json").absoluteString] =
                GamiStubURLProtocol.StubResponse(body: try! JSONEncoder().encode(manifest))
            for file in files {
                routes[base.appendingPathComponent(file.path).absoluteString] =
                    GamiStubURLProtocol.StubResponse(body: file.body)
            }
            return routes
        }
    }

    private func makeCaches() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("digia-gami-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GamiStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeStack(cap: Int = SkinBundleCache.defaultMaxTotalBytes) async
        -> (caches: URL, cache: SkinBundleCache, prefetcher: SkinPrefetcher)
    {
        let caches = makeCaches()
        let session = makeSession()
        let cache = await SkinBundleCache(cachesDirectory: caches, session: session, maxTotalBytes: cap)
        return (caches, cache, SkinPrefetcher(cache: cache, session: session))
    }

    // MARK: - Prefetch

    @Test("A bundle over 3 MB plus margin is rejected before any file downloads")
    func totalSizeOverBudgetIsRejected() async {
        let (_, cache, prefetcher) = await makeStack()
        let base = URL(string: "https://cdn.example/gamification/skins/big/1")!
        let manifest = SkinBundleManifest(files: [
            .init(path: "index.html", size: 900_000),
            .init(path: "js/app.js", size: 900_000),
            .init(path: "css/app.css", size: 900_000),
            .init(path: "assets/bg.webp", size: 900_000),
        ])
        GamiStubURLProtocol.reset(routes: [
            base.appendingPathComponent("files.json").absoluteString:
                GamiStubURLProtocol.StubResponse(body: try! JSONEncoder().encode(manifest)),
        ])

        let result = await prefetcher.prefetch(bundleUrl: base.appendingPathComponent("index.html"))

        #expect(result == .skipped(.overBudget))
        #expect(await cache.isComplete(bundleUrl: base.appendingPathComponent("index.html")) == false)
        #expect(GamiStubURLProtocol.requestedURLs.count == 1)
    }

    @Test("A file over 1 MB is rejected before any file downloads")
    func perFileSizeOverBudgetIsRejected() async {
        let (_, cache, prefetcher) = await makeStack()
        let base = URL(string: "https://cdn.example/gamification/skins/fat/1")!
        let manifest = SkinBundleManifest(files: [
            .init(path: "index.html", size: 12),
            .init(path: "assets/poster.webp", size: 2_000_000),
        ])
        GamiStubURLProtocol.reset(routes: [
            base.appendingPathComponent("files.json").absoluteString:
                GamiStubURLProtocol.StubResponse(body: try! JSONEncoder().encode(manifest)),
        ])

        let result = await prefetcher.prefetch(bundleUrl: base.appendingPathComponent("index.html"))

        #expect(result == .skipped(.fileTooLarge))
        #expect(await cache.isComplete(bundleUrl: base.appendingPathComponent("index.html")) == false)
        #expect(GamiStubURLProtocol.requestedURLs.count == 1)
    }

    @Test("A verified bundle moves into the cache with its exact bytes")
    func successfulPrefetchMovesVerifiedFilesIntoCache() async {
        let (_, cache, prefetcher) = await makeStack()
        let bundle = StubbedBundle(
            base: URL(string: "https://cdn.example/gamification/skins/testSkin/1")!,
            files: [
                (path: "index.html", body: Data("<html></html>".utf8)),
                (path: "js/app.js", body: Data("console.log(1)".utf8)),
            ])
        GamiStubURLProtocol.reset(routes: bundle.routes)

        let result = await prefetcher.prefetch(bundleUrl: bundle.bundleUrl)

        #expect(result == .downloaded)
        #expect(await cache.isComplete(bundleUrl: bundle.bundleUrl))
    }

    @Test("A file whose size mismatches files.json discards the whole download")
    func sizeMismatchDiscardsDownload() async {
        let (caches, cache, prefetcher) = await makeStack()
        let bundle = StubbedBundle(
            base: URL(string: "https://cdn.example/gamification/skins/corrupt/1")!,
            files: [(path: "index.html", body: Data("<html></html>".utf8))])
        var routes = bundle.routes
        // The CDN serves one byte short of the manifest size.
        let fileURL = bundle.base.appendingPathComponent("index.html").absoluteString
        routes[fileURL] = GamiStubURLProtocol.StubResponse(body: Data("<html></htm".utf8))
        GamiStubURLProtocol.reset(routes: routes)

        let result = await prefetcher.prefetch(bundleUrl: bundle.bundleUrl)

        #expect(result == .failed)
        #expect(await cache.isComplete(bundleUrl: bundle.bundleUrl) == false)
        // Temp-then-move: the failed download leaves nothing behind in the cache.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: caches, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("A failed download is dropped and retried at the next trigger")
    func failedDownloadIsRetriedOnNextTrigger() async {
        let (_, cache, prefetcher) = await makeStack()
        let bundle = StubbedBundle(
            base: URL(string: "https://cdn.example/gamification/skins/flaky/1")!,
            files: [(path: "index.html", body: Data("<html></html>".utf8))])
        GamiStubURLProtocol.reset(routes: bundle.routes)
        GamiStubURLProtocol.setFailURLs([bundle.base.appendingPathComponent("index.html").absoluteString])

        let first = await prefetcher.prefetch(bundleUrl: bundle.bundleUrl)
        #expect(first == .failed)
        #expect(await cache.isComplete(bundleUrl: bundle.bundleUrl) == false)

        GamiStubURLProtocol.setFailURLs([])
        let second = await prefetcher.prefetch(bundleUrl: bundle.bundleUrl)
        #expect(second == .downloaded)
        #expect(await cache.isComplete(bundleUrl: bundle.bundleUrl))
    }

    @Test("A complete bundle skips the network entirely on the next trigger")
    func skipWhenCompletePerformsNoNetwork() async {
        let (_, _, prefetcher) = await makeStack()
        let bundle = StubbedBundle(
            base: URL(string: "https://cdn.example/gamification/skins/cached/1")!,
            files: [(path: "index.html", body: Data("<html></html>".utf8))])
        GamiStubURLProtocol.reset(routes: bundle.routes)

        #expect(await prefetcher.prefetch(bundleUrl: bundle.bundleUrl) == .downloaded)
        let afterFirst = GamiStubURLProtocol.requestedURLs.count
        #expect(afterFirst == 2)

        #expect(await prefetcher.prefetch(bundleUrl: bundle.bundleUrl) == .alreadyCached)
        #expect(GamiStubURLProtocol.requestedURLs.count == afterFirst)
    }

    @Test("Concurrent triggers download one bundle at a time")
    func concurrentPrefetchesDoNotOverlap() async {
        let (_, _, prefetcher) = await makeStack()
        let bundleA = StubbedBundle(
            base: URL(string: "https://cdn.example/gamification/skins/a/1")!,
            files: [
                (path: "index.html", body: Data("aaaa".utf8)),
                (path: "js/app.js", body: Data("bbbb".utf8)),
            ])
        let bundleB = StubbedBundle(
            base: URL(string: "https://cdn.example/gamification/skins/b/1")!,
            files: [
                (path: "index.html", body: Data("cccc".utf8)),
                (path: "js/app.js", body: Data("dddd".utf8)),
            ])
        GamiStubURLProtocol.reset(routes: bundleA.routes.merging(bundleB.routes) { a, _ in a }, latency: 0.05)

        async let first = prefetcher.prefetch(bundleUrl: bundleA.bundleUrl)
        async let second = prefetcher.prefetch(bundleUrl: bundleB.bundleUrl)
        let results = await [first, second]

        #expect(results == [.downloaded, .downloaded])
        #expect(GamiStubURLProtocol.peakInFlight == 1)
    }

    // MARK: - Eviction

    @Test("LRU eviction drops the oldest whole bundle over the cap")
    func lruEvictionDropsOldestWholeBundle() async {
        let (_, cache, prefetcher) = await makeStack(cap: 100)
        let bundleA = StubbedBundle(
            base: URL(string: "https://cdn.example/gamification/skins/old/1")!,
            files: [(path: "index.html", body: Data(repeating: 0x61, count: 60))])
        let bundleB = StubbedBundle(
            base: URL(string: "https://cdn.example/gamification/skins/new/1")!,
            files: [(path: "index.html", body: Data(repeating: 0x62, count: 60))])
        GamiStubURLProtocol.reset(routes: bundleA.routes.merging(bundleB.routes) { a, _ in a })

        #expect(await prefetcher.prefetch(bundleUrl: bundleA.bundleUrl) == .downloaded)
        #expect(await prefetcher.prefetch(bundleUrl: bundleB.bundleUrl) == .downloaded)

        #expect(await cache.isComplete(bundleUrl: bundleA.bundleUrl) == false)
        #expect(await cache.isComplete(bundleUrl: bundleB.bundleUrl))
    }

    @Test("An open bundle is never evicted")
    func openBundleIsNeverEvicted() async {
        let (_, cache, prefetcher) = await makeStack(cap: 150)
        func bundle(_ name: String, byte: UInt8) -> StubbedBundle {
            StubbedBundle(
                base: URL(string: "https://cdn.example/gamification/skins/\(name)/1")!,
                files: [(path: "index.html", body: Data(repeating: byte, count: 60))])
        }
        let bundleA = bundle("keep", byte: 0x61)
        let bundleB = bundle("mid", byte: 0x62)
        let bundleC = bundle("last", byte: 0x63)
        GamiStubURLProtocol.reset(routes:
            bundleA.routes.merging(bundleB.routes) { a, _ in a }.merging(bundleC.routes) { a, _ in a })

        #expect(await prefetcher.prefetch(bundleUrl: bundleA.bundleUrl) == .downloaded)
        await cache.markOpen(bundleUrl: bundleA.bundleUrl)
        #expect(await prefetcher.prefetch(bundleUrl: bundleB.bundleUrl) == .downloaded)
        #expect(await prefetcher.prefetch(bundleUrl: bundleC.bundleUrl) == .downloaded)
        await cache.markClosed(bundleUrl: bundleA.bundleUrl)

        #expect(await cache.isComplete(bundleUrl: bundleA.bundleUrl))
        #expect(await cache.isComplete(bundleUrl: bundleB.bundleUrl) == false)
        #expect(await cache.isComplete(bundleUrl: bundleC.bundleUrl))
    }

    // MARK: - Scheme handler

    @MainActor
    @Test("The scheme handler serves cached files with the CSP header and mime type")
    func schemeHandlerServesCachedFile() async {
        let (_, cache, prefetcher) = await makeStack()
        let html = Data("<html></html>".utf8)
        let js = Data("console.log(1)".utf8)
        let bundle = StubbedBundle(
            base: URL(string: "https://cdn.example/gamification/skins/web/1")!,
            files: [(path: "index.html", body: html), (path: "js/app.js", body: js)])
        GamiStubURLProtocol.reset(routes: bundle.routes)
        #expect(await prefetcher.prefetch(bundleUrl: bundle.bundleUrl) == .downloaded)

        for (path, expectedBody, expectedMime) in [
            ("index.html", html, "text/html"),
            ("js/app.js", js, "text/javascript"),
        ] as [(String, Data, String)] {
            let schemeURL = SkinBundleCache.schemeURL(
                forCDNURL: bundle.base.appendingPathComponent(path))!
            let task = FakeSchemeTask(url: schemeURL)
            cache.webView(WKWebView(), start: task)
            let http = task.response as? HTTPURLResponse
            #expect(task.finished)
            #expect(task.failure == nil)
            #expect(http?.value(forHTTPHeaderField: "Content-Type") == expectedMime)
            #expect(http?.value(forHTTPHeaderField: "Content-Security-Policy")
                == SkinBundleCache.contentSecurityPolicy)
            #expect(task.receivedData == expectedBody)
        }
    }

    @MainActor
    @Test("The scheme handler falls back to the CDN for an incomplete bundle")
    func schemeHandlerFallsBackToCDN() async throws {
        let (_, cache, _) = await makeStack()
        let cdnURL = URL(string: "https://cdn.example/gamification/skins/missing/1/index.html")!
        let body = Data("<html></html>".utf8)
        GamiStubURLProtocol.reset(routes: [
            cdnURL.absoluteString: GamiStubURLProtocol.StubResponse(
                headers: ["Content-Type": "text/html"], body: body),
        ])
        #expect(await cache.isComplete(bundleUrl: cdnURL) == false)

        let task = FakeSchemeTask(url: SkinBundleCache.schemeURL(forCDNURL: cdnURL)!)
        cache.webView(WKWebView(), start: task)
        let deadline = Date().addingTimeInterval(5)
        while task.response == nil, task.failure == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let http = task.response as? HTTPURLResponse
        #expect(task.failure == nil)
        #expect(task.receivedData == body)
        #expect(http?.value(forHTTPHeaderField: "Content-Security-Policy")
            == SkinBundleCache.contentSecurityPolicy)
    }
}
