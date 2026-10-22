import Foundation
@testable import DigiaEngage
import Testing

@Suite("Digia video file cache", .tags(.canvas, .media, .unit))
struct DigiaVideoFileCacheTests {

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigiaVideoCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("returns nil when file is not cached")
    func returnsNilWhenNotCached() async throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(directory: tempDir) }

        let cache = DigiaVideoFileCache(directory: tempDir, maxBytes: 10_000)
        let remoteURL = try #require(URL(string: "https://cdn.example.com/video1.mp4"))

        let cached = await cache.cachedURL(for: remoteURL)
        #expect(cached == nil)
    }

    @Test("cachedURL deletes existing local file and returns nil if file exceeds maxBytes")
    func deletesOversizeFile() async throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(directory: tempDir) }

        let remoteURL = try #require(URL(string: "https://cdn.example.com/oversize.mp4"))
        let cache = DigiaVideoFileCache(directory: tempDir, maxBytes: 100)

        let fileName = DigiaVideoFileCache.cacheFileName(for: remoteURL)
        let destination = tempDir.appendingPathComponent(fileName)
        try Data(repeating: 0x42, count: 200).write(to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let cached = await cache.cachedURL(for: remoteURL)
        #expect(cached == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("removes stale partial download files when preparing directory")
    func removesStalePartialFiles() async throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(directory: tempDir) }

        let stalePartial = tempDir.appendingPathComponent(".temp-download-123.partial")
        try Data("partial content".utf8).write(to: stalePartial)
        #expect(FileManager.default.fileExists(atPath: stalePartial.path))

        let cache = DigiaVideoFileCache(directory: tempDir, maxBytes: 50_000)
        let remoteURL = try #require(URL(string: "https://cdn.example.com/check.mp4"))
        _ = await cache.cachedURL(for: remoteURL)

        #expect(!FileManager.default.fileExists(atPath: stalePartial.path))
    }

    @Test("peekCachedURL does not touch modification date while cachedURL touches it")
    func peekVsCachedTouchBehavior() async throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(directory: tempDir) }

        let remoteURL = try #require(URL(string: "https://cdn.example.com/touch-test.mp4"))
        let cache = DigiaVideoFileCache(directory: tempDir, maxBytes: 100_000)

        let fileName = DigiaVideoFileCache.cacheFileName(for: remoteURL)
        let destination = tempDir.appendingPathComponent(fileName)
        try Data("video-bytes".utf8).write(to: destination)

        let pastDate = Date(timeIntervalSinceNow: -500)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: destination.path)

        // peekCachedURL returns file and preserves past modification date
        let peeked = await cache.peekCachedURL(for: remoteURL)
        #expect(peeked == destination)
        let attrAfterPeek = try FileManager.default.attributesOfItem(atPath: destination.path)
        let dateAfterPeek = attrAfterPeek[.modificationDate] as? Date
        #expect(abs(dateAfterPeek!.timeIntervalSince(pastDate)) < 1.0)

        // cachedURL returns file and updates modification date to now
        let cached = await cache.cachedURL(for: remoteURL)
        #expect(cached == destination)
        let attrAfterCached = try FileManager.default.attributesOfItem(atPath: destination.path)
        let dateAfterCached = attrAfterCached[.modificationDate] as? Date
        #expect(dateAfterCached!.timeIntervalSince(pastDate) > 400)
    }

    @Test("enforces LRU eviction when files exceed maxBytes")
    func lruEvictionUnderCapacityLimit() async throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(directory: tempDir) }

        let fileA = tempDir.appendingPathComponent("videoA.mp4")
        let fileB = tempDir.appendingPathComponent("videoB.mp4")

        try Data(repeating: 0xAA, count: 60).write(to: fileA)
        try Data(repeating: 0xBB, count: 60).write(to: fileB)

        // Set fileA older than fileB
        let pastDate = Date(timeIntervalSinceNow: -100)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: fileA.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileB.path)

        // MaxBytes is 80: total is 120, so oldest (fileA) must be evicted upon directory preparation
        let cache = DigiaVideoFileCache(directory: tempDir, maxBytes: 80)
        let remoteURL = try #require(URL(string: "https://cdn.example.com/query.mp4"))
        _ = await cache.cachedURL(for: remoteURL)

        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fileB.path))
    }

    @Test("cooling down prevents immediate retries after network error")
    func coolingDownRejectsImmediateRetries() async throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(directory: tempDir) }

        // A mock URLSession configuration that always fails
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let session = URLSession(configuration: config)

        let cache = DigiaVideoFileCache(session: session, directory: tempDir, maxBytes: 10_000)
        let failingURL = try #require(URL(string: "https://failing.invalid/video.mp4"))

        // First attempt fails due to FailingURLProtocol
        do {
            _ = try await cache.localURL(for: failingURL, priority: .fullScreen)
            Issue.record("Expected download to fail")
        } catch {
            // Expected
        }

        // Second immediate attempt should be rejected by cooldown without hitting network
        do {
            _ = try await cache.localURL(for: failingURL, priority: .fullScreen)
            Issue.record("Expected cooldown rejection")
        } catch let error as URLError {
            #expect(error.code == .cannotLoadFromNetwork)
        }
    }
}

private final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}
