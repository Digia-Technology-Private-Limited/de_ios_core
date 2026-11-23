import Foundation
import Testing

@testable import DigiaEngage

/// Guards the single-file skin cache: the production lines are
/// `directoryName`/`safeSkinId`, the hit/miss checks, the download
/// validation, and the LRU eviction. The network runs through
/// `MockNetworkClient`, never the wire.
@Suite("Game skin file cache", .serialized, .tags(.unit, .game))
struct SkinFileCacheTests {
    private func makeCache(
        client: MockNetworkClient? = nil, caches: URL? = nil
    ) -> (SkinFileCache, MockNetworkClient, URL) {
        let directory = caches ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("test-skins-\(UUID().uuidString)", isDirectory: true)
        let client = client ?? MockNetworkClient()
        return (
            SkinFileCache(cachesDirectory: directory, networkClient: client), client, directory)
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
        let (cache, _, _) = makeCache()

        #expect(cache.cachedFile(skinId: "wheel", version: 3) == nil)
        let data = Data("<html></html>".utf8)
        let file = try cache.store(skinId: "wheel", version: 3, data: data)

        // Guards the existence check in cachedFile; versions stay isolated.
        // The stored bytes carry the CSP meta tag, so equality is against
        // the injected form, not the raw input.
        #expect(cache.cachedFile(skinId: "wheel", version: 3) == file)
        #expect(try Data(contentsOf: file) == SkinFileCache.withCspMetaTag(data))
        #expect(cache.cachedFile(skinId: "wheel", version: 4) == nil)
        #expect(cache.cachedFile(skinId: "chest", version: 3) == nil)
    }

    @Test("download stores the single file and does not re-download")
    func downloadCaches() async throws {
        let (cache, client, _) = makeCache()
        let url = "https://cdn.example.com/s/wheel/3/index.html"
        client.enqueueResponse(url: url, statusCode: 200, body: "<html>v3 DigiaBridge</html>")

        let first = try await cache.download(bundleUrl: url, skinId: "wheel", version: 3)
        let second = try await cache.download(bundleUrl: url, skinId: "wheel", version: 3)

        #expect(first == second)
        // The stored copy carries the CSP meta tag.
        #expect(
            try String(data: Data(contentsOf: first), encoding: .utf8)
                == String(data: SkinFileCache.withCspMetaTag(Data("<html>v3 DigiaBridge</html>".utf8)), encoding: .utf8))
        // Guards the cached-first check in download.
        #expect(client.requestCount == 1)
    }

    @Test("bad URLs, statuses and bodies throw")
    func downloadFailures() async {
        let (cache, client, _) = makeCache()

        // Guards the scheme check: only http(s) downloads.
        await #expect(throws: SkinFileCacheError.self) {
            try await cache.download(bundleUrl: "not a url %%", skinId: "wheel", version: 1)
        }

        let url = "https://cdn.example.com/s/wheel/3/index.html"
        client.enqueueResponse(url: url, statusCode: 500, body: "")
        // Guards the status check.
        await #expect(throws: SkinFileCacheError.self) {
            try await cache.download(bundleUrl: url, skinId: "wheel", version: 2)
        }
        #expect(cache.cachedFile(skinId: "wheel", version: 2) == nil)

        // Guards the bridge-marker check: a captive portal answering 200 with
        // its own page must not be cached as the skin.
        client.enqueueResponse(url: url, statusCode: 200, body: "<html>Sign in to Wi-Fi</html>")
        await #expect(throws: SkinFileCacheError.self) {
            try await cache.download(bundleUrl: url, skinId: "wheel", version: 4)
        }
        #expect(cache.cachedFile(skinId: "wheel", version: 4) == nil)
    }

    @Test("prefetch skips cached entries and drops failures")
    func prefetchDropsFailures() async {
        let (cache, client, _) = makeCache()
        client.enqueueResponse(
            url: "https://cdn.example.com/s/wheel/3/index.html",
            statusCode: 200, body: "<html>DigiaBridge</html>")

        await cache.prefetch([
            (bundleUrl: "https://cdn.example.com/s/wheel/3/index.html", skinId: "wheel", version: 3),
            (bundleUrl: "broken", skinId: "broken", version: 1),
        ])

        #expect(cache.cachedFile(skinId: "wheel", version: 3) != nil)
        #expect(cache.cachedFile(skinId: "broken", version: 1) == nil)
    }

    @Test("eviction drops the least-recently-used entry until under the cap")
    func lruEviction() throws {
        let (cache, _, _) = makeCache()
        // One entry stays under the 3 MB single-file cap; six of them exceed
        // the 16 MB total by one entry.
        let threeMB = 3 * 1024 * 1024
        let bytes = Data(repeating: 0x61, count: threeMB)

        for version in 1...5 {
            _ = try cache.store(skinId: "wheel", version: version, data: bytes)
        }
        let v1 = try #require(cache.fileURL(skinId: "wheel", version: 1))
        // Backdates v1 past every other write, so the order below reads off
        // recency alone and never off filesystem timestamp granularity.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: v1.path)
        // A hit refreshes recency: v1 now outlives v2.
        #expect(cache.cachedFile(skinId: "wheel", version: 1) != nil)
        _ = try cache.store(skinId: "wheel", version: 6, data: bytes)

        // Guards the oldest-first eviction: the untouched v2 is the one
        // that goes.
        #expect(cache.cachedFile(skinId: "wheel", version: 1) != nil)
        #expect(cache.cachedFile(skinId: "wheel", version: 2) == nil)
        for version in 3...6 {
            #expect(cache.cachedFile(skinId: "wheel", version: version) != nil)
        }
    }
}
