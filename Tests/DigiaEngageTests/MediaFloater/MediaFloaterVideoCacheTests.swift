import Foundation
import Testing
@testable import DigiaEngage

/// The story video cache downloading for real: `DigiaVideoFileCache` with its own downloader,
/// partial-file writer, publisher, queue and eviction, over a scripted origin
/// (`MediaFloaterVideoOrigin`) instead of a loopback server. What a player is handed is the cache's
/// answer, so the tests read that answer, the origin's request log and the cache folder.
///
/// Port of the cache scenarios of `flutter/core/test/fixture_behaviour/surface_story_video_*_test.dart`
/// (`download`, `break_off`, `oversize`, `eviction`, `order`, `priority`) and their
/// `support/story_video_cache_support.dart`. Flutter drives them through the inline story strip's
/// fixture; the strip-to-cache wiring is not this file's subject, so the cache is driven directly
/// through the calls the strip and the player make (`prepare` for a rail's look-ahead demand,
/// `localURL` for a player waiting on its file). Already covered by
/// `Components/Canvas/DigiaVideoFileCacheTests.swift`: a stale partial is cleared at start, an
/// oversized cached file is dropped, peek vs touch, LRU eviction at start, and the failure cooldown.
@Suite("Media: story video cache downloads", .serialized, .tags(.integration, .media),
       .timeLimit(.minutes(1)))
struct MediaFloaterVideoCacheTests {

    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaFloaterVideoCache-\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    /// Every file the cache folder holds, by name.
    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func waitFor(
        _ what: String, timeout: TimeInterval = 10, _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func pause(_ seconds: TimeInterval = 0.3) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - surface_story_video_download

    // Fails if: digia_video_streaming.swift `enqueue` `if var download = active[key] {` ->
    // `if false, var download = active[key] {` (a second player asking while the first download
    // runs starts a second transfer of the same video).
    @Test("a video three players ask for at once is downloaded once, kept whole, and then served from the file")
    func downloadedOnceAndKeptWhole() async throws {
        defer { cleanUp() }
        let origin = MediaFloaterVideoOrigin()
        // Larger than the 64 KB write buffer, so the file is written in several flushes.
        let video = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        origin.reply("/movie.mp4", with: .body(video))
        origin.holdAll = true
        let cache = DigiaVideoFileCache(session: origin.session, directory: folder, maxBytes: 1_000_000)
        let url = origin.url("/movie.mp4")

        async let first = cache.localURL(for: url, priority: .fullScreen)
        try await waitFor("the first download to start") { origin.requests.count == 1 }
        async let second = cache.localURL(for: url, priority: .eligible)
        async let third = cache.localURL(for: url, priority: .lookAhead)
        try await pause()
        origin.releaseAll()

        let local = try await [first, second, third]
        #expect(Set(local).count == 1, "all three players get the same file")
        #expect(origin.requests == ["/movie.mp4"], "one transfer for three players")
        let kept = try #require(local.first)
        #expect(try Data(contentsOf: kept) == video, "the whole file, byte for byte")
        #expect(!files().contains { $0.hasSuffix(".partial") })

        // The next player is given the file without asking the origin again.
        #expect(try await cache.localURL(for: url, priority: .fullScreen) == kept)
        #expect(await cache.peekCachedURL(for: url) == kept)
        #expect(origin.requests.count == 1)
    }

    // MARK: - surface_story_video_break_off

    // Fails if: digia_video_streaming.swift `download` `expectedBytes < 0 || receivedBytes ==
    // expectedBytes else {` -> `true else {` (the truncated file is published as the video).
    @Test("a download that breaks off leaves nothing behind and is not tried again while it cools down")
    func breakOffLeavesNothing() async throws {
        defer { cleanUp() }
        let origin = MediaFloaterVideoOrigin()
        origin.reply("/movie.mp4", with: .breakOff(announced: 50_000, sent: 10))
        let cache = DigiaVideoFileCache(session: origin.session, directory: folder, maxBytes: 1_000_000)
        let url = origin.url("/movie.mp4")

        await #expect(throws: (any Error).self) { try await cache.localURL(for: url, priority: .fullScreen) }
        #expect(files().isEmpty, "no video and no partial: \(files())")
        #expect(await cache.peekCachedURL(for: url) == nil)

        // The strip comes round to it again: no second attempt while it cools down.
        let again = await #expect(throws: URLError.self) {
            try await cache.localURL(for: url, priority: .fullScreen)
        }
        #expect(again?.code == .cannotLoadFromNetwork)
        #expect(origin.requests == ["/movie.mp4"])
    }

    // MARK: - surface_story_video_oversize

    // Fails if: digia_video_streaming.swift `download` `guard expectedBytes < 0 || expectedBytes <=
    // maxBytes else {` -> `guard true else {` (the client waits on a body it can never keep).
    @Test("a video announced as larger than the cache allows is refused at once and stores nothing")
    func oversizeAnnouncementIsRefused() async throws {
        defer { cleanUp() }
        let origin = MediaFloaterVideoOrigin()
        origin.reply("/movie.mp4", with: .announceOnly(announced: 300_000))
        let cache = DigiaVideoFileCache(session: origin.session, directory: folder, maxBytes: 100_000)

        let refused = await #expect(throws: URLError.self) {
            try await cache.localURL(for: origin.url("/movie.mp4"), priority: .fullScreen)
        }
        #expect(refused?.code == .dataLengthExceedsMaximum)
        // Told the size up front, the client walks away rather than wait for the body.
        try await waitFor("the client to hang up", timeout: 1.5) { origin.hungUp == ["/movie.mp4"] }
        #expect(files().isEmpty, "\(files())")
    }

    // Not in Flutter's set; the same "keep nothing that is not the video" rule for an error page.
    // Fails if: digia_video_streaming.swift `download` `http.statusCode == 200 else {` -> `true else {`
    // (the 404 page is kept and handed to the player as the video).
    @Test("an error page is never kept as the video")
    func errorPageIsNotKept() async throws {
        defer { cleanUp() }
        let origin = MediaFloaterVideoOrigin()
        origin.reply("/missing.mp4", with: .status(404))
        let cache = DigiaVideoFileCache(session: origin.session, directory: folder, maxBytes: 100_000)

        let refused = await #expect(throws: URLError.self) {
            try await cache.localURL(for: origin.url("/missing.mp4"), priority: .fullScreen)
        }
        #expect(refused?.code == .badServerResponse)
        #expect(files().isEmpty, "\(files())")
    }

    // MARK: - surface_story_video_eviction

    // Fails if: digia_video_streaming.swift `publish` `evictOldFiles(keeping: destination)` is
    // deleted (only a restart would bring the cache back under its limit).
    @Test("a new video that takes the cache over its limit pushes out the one used longest ago and keeps the rest")
    func newVideoEvictsLeastRecentlyUsed() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func seed(_ name: String, _ bytes: Int, lastUsed: TimeInterval) throws {
            let file = folder.appendingPathComponent(name)
            try Data(repeating: 1, count: bytes).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: lastUsed)], ofItemAtPath: file.path)
        }
        // Together just under the limit, so nothing is dropped when the cache opens; one more
        // small video tips it over.
        try seed("used-long-ago.mp4", 5_000, lastUsed: 1_577_836_800) // 2020
        try seed("used-recently.mp4", 4_500, lastUsed: 1_609_459_200) // 2021
        let origin = MediaFloaterVideoOrigin()
        origin.reply("/movie.mp4", with: .body(Data(repeating: 7, count: 1_000)))
        let cache = DigiaVideoFileCache(session: origin.session, directory: folder, maxBytes: 10_000)
        let url = origin.url("/movie.mp4")
        #expect(await cache.peekCachedURL(for: url) == nil)
        #expect(files().count == 2, "under the limit, nothing is dropped at start")

        let kept = try await cache.localURL(for: url, priority: .fullScreen)

        #expect(files() == [kept.lastPathComponent, "used-recently.mp4"].sorted())
    }

    // MARK: - surface_story_video_order

    // Fails if: digia_video_streaming.swift `startDownloadsIfPossible` `return lhs.value.order <
    // rhs.value.order` -> `return lhs.value.order > rhs.value.order`.
    @Test("videos waiting for a download slot are served first come, first served, two at a time")
    func equalDemandIsServedInOrder() async throws {
        defer { cleanUp() }
        let origin = MediaFloaterVideoOrigin()
        origin.holdAll = true
        let cache = DigiaVideoFileCache(session: origin.session, directory: folder, maxBytes: 1_000_000)
        let paths = (0..<4).map { "/movie-\($0).mp4" }
        let rail = UUID()

        await cache.prepare(paths.map { .init(url: origin.url($0), priority: .eligible) }, owner: rail)
        try await waitFor("two downloads") { origin.requests.count == 2 }
        try await pause()
        #expect(origin.requests.count == 2, "two at a time, no more")

        origin.release(origin.requests[0])
        try await waitFor("a third download") { origin.requests.count == 3 }
        origin.release(origin.requests[1])
        try await waitFor("a fourth download") { origin.requests.count == 4 }

        // The first two start together, so they may reach the origin in either order.
        #expect(Set(origin.requests.prefix(2)) == Set(paths.prefix(2)))
        #expect(Array(origin.requests.suffix(2)) == Array(paths.suffix(2)),
                "item by item, the order the rail asked in")
        origin.releaseAll()
        try await waitFor("all four kept") { files().count == 4 }
    }

    // MARK: - surface_story_video_priority

    // Fails if: digia_video_streaming.swift `startDownloadsIfPossible` `return lhs.value.priority >
    // rhs.value.priority` -> `return lhs.value.priority < rhs.value.priority`.
    // Fails if: digia_video_streaming.swift `maximumActiveDownloads = 2` -> `= 3`.
    @Test("a story someone opens jumps ahead of the downloads still waiting, and no more than two run at once")
    func openedStoryJumpsTheQueue() async throws {
        defer { cleanUp() }
        let origin = MediaFloaterVideoOrigin()
        origin.holdAll = true
        let cache = DigiaVideoFileCache(session: origin.session, directory: folder, maxBytes: 1_000_000)
        let paths = (0..<4).map { "/movie-\($0).mp4" }

        await cache.prepare(paths.map { .init(url: origin.url($0), priority: .lookAhead) }, owner: UUID())
        try await waitFor("two downloads") { origin.requests.count == 2 }
        try await pause()
        #expect(Set(origin.requests) == Set(paths.prefix(2)), "two at a time, no more")

        // Someone opens the last of the two still waiting their turn.
        async let opened = cache.localURL(for: origin.url(paths[3]), priority: .fullScreen)
        try await pause()
        origin.release(origin.requests[0])
        try await waitFor("a third download") { origin.requests.count == 3 }

        #expect(origin.requests[2] == paths[3], "the opened story goes before the earlier one that waits")
        origin.releaseAll()
        _ = try await opened
    }

    // MARK: - Demand that goes away (no Flutter counterpart in the fixture set)

    // Fails if: digia_video_streaming.swift `removeQueuedDemand` `download.demandPriorities[owner] =
    // nil` is deleted (a rail that scrolled away still downloads everything it once looked ahead to).
    @Test("a rail's look-ahead that has not started is dropped when the rail goes away")
    func clearedDemandIsNeverFetched() async throws {
        defer { cleanUp() }
        let origin = MediaFloaterVideoOrigin()
        origin.holdAll = true
        let cache = DigiaVideoFileCache(session: origin.session, directory: folder, maxBytes: 1_000_000)
        let paths = (0..<3).map { "/movie-\($0).mp4" }
        let rail = UUID()

        await cache.prepare(paths.map { .init(url: origin.url($0), priority: .lookAhead) }, owner: rail)
        try await waitFor("two downloads") { origin.requests.count == 2 }
        await cache.clearDemand(owner: rail)
        origin.releaseAll()
        // The transfers already running finish and are kept.
        try await waitFor("the two running downloads kept") { files().count == 2 }
        try await pause()

        #expect(Set(origin.requests) == Set(paths.prefix(2)), "the third was never fetched")
    }

    // Fails if: digia_video_streaming.swift `cancelWaiter` `queued[key] = download.isNeeded ?
    // download : nil` -> `queued[key] = download` (a player that gave up still costs a download).
    @Test("a player that stops waiting for a queued video gets a cancellation and the video is not fetched")
    func cancelledQueuedWaiterIsNotFetched() async throws {
        defer { cleanUp() }
        let origin = MediaFloaterVideoOrigin()
        origin.holdAll = true
        let cache = DigiaVideoFileCache(session: origin.session, directory: folder, maxBytes: 1_000_000)

        await cache.prepare(
            ["/a.mp4", "/b.mp4"].map { .init(url: origin.url($0), priority: .lookAhead) }, owner: UUID())
        try await waitFor("both slots busy") { origin.requests.count == 2 }
        let player = Task { try await cache.localURL(for: origin.url("/c.mp4"), priority: .fullScreen) }
        try await pause()
        player.cancel()

        await #expect(throws: CancellationError.self) { try await player.value }
        origin.releaseAll()
        try await waitFor("the two running downloads kept") { files().count == 2 }
        try await pause()
        #expect(!origin.requests.contains("/c.mp4"))
    }

    // Fails if: digia_video_streaming.swift `cancelWaiter`'s active-download branch
    // `waiter.continuation.resume(throwing: CancellationError())` is deleted (the player hangs until
    // the whole transfer ends).
    @Test("a player that stops waiting for a running download is let go at once, and the download still lands in the cache")
    func cancelledActiveWaiterStillPopulatesCache() async throws {
        defer { cleanUp() }
        let origin = MediaFloaterVideoOrigin()
        origin.holdAll = true
        let cache = DigiaVideoFileCache(session: origin.session, directory: folder, maxBytes: 1_000_000)
        let url = origin.url("/movie.mp4")

        let player = Task { try await cache.localURL(for: url, priority: .fullScreen) }
        try await waitFor("the download to start") { origin.requests.count == 1 }
        player.cancel()
        await #expect(throws: CancellationError.self) { try await player.value }

        origin.releaseAll()
        try await waitFor("the video kept") { await cache.peekCachedURL(for: url) != nil }
        #expect(origin.requests == ["/movie.mp4"])
    }
}
