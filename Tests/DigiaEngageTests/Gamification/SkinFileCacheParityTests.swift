import Foundation
import Testing

@testable import DigiaEngage

/// Android parity guards for the single-file skin cache: oversized entries
/// on disk are misses (never served), and crash-orphaned temps are swept on
/// store. The production lines are the size check in `cachedFile` and the
/// stray sweep in `store`. Complements `SkinFileCacheTests`, which owns the
/// hit/miss, download and eviction coverage.
@Suite("Game skin file cache parity", .serialized, .tags(.unit, .game))
struct SkinFileCacheParityTests {
    private func makeCache() -> SkinFileCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-skins-parity-\(UUID().uuidString)", isDirectory: true)
        return SkinFileCache(cachesDirectory: directory, networkClient: MockNetworkClient())
    }

    @Test("an oversized entry on disk is a miss")
    func oversizedEntryIsMiss() throws {
        let cache = makeCache()
        guard let file = cache.fileURL(skinId: "wheel", version: 1) else {
            Issue.record("no file URL")
            return
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oversized = Data(
            repeating: 0x61, count: Int(SkinFileCache.singleFileMaxBytes) + 1)
        try oversized.write(to: file)

        // Guards the size cap in cachedFile: Android's lookup misses here too.
        #expect(cache.cachedFile(skinId: "wheel", version: 1) == nil)
    }

    @Test("an empty entry on disk is a miss")
    func emptyEntryIsMiss() throws {
        let cache = makeCache()
        guard let file = cache.fileURL(skinId: "wheel", version: 1) else {
            Issue.record("no file URL")
            return
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)

        // Guards the non-empty check in cachedFile: Android misses these too.
        #expect(cache.cachedFile(skinId: "wheel", version: 1) == nil)
    }

    @Test("store sweeps orphaned temps")
    func storeSweepsTemps() throws {
        let cache = makeCache()
        _ = try cache.store(skinId: "wheel", version: 1, data: Data("<html></html>".utf8))
        guard let directory = cache.fileURL(skinId: "wheel", version: 1)?
            .deletingLastPathComponent()
        else {
            Issue.record("no file URL")
            return
        }
        let orphan = directory.appendingPathComponent(SkinFileCache.tempFileName)
        try Data("partial".utf8).write(to: orphan)

        _ = try cache.store(skinId: "wheel", version: 2, data: Data("<html></html>".utf8))

        // Guards the stray sweep in store.
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(cache.cachedFile(skinId: "wheel", version: 1) != nil)
        #expect(cache.cachedFile(skinId: "wheel", version: 2) != nil)
    }
}
