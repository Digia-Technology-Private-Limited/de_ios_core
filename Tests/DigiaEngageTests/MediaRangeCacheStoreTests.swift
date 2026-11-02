import Foundation
import Testing
@testable import DigiaEngage

// MARK: - Fakes

/// Fake fetch layer: serves canned bodies per URL, records every call, and can
/// delay responses to force reader overlap or observe cancellation.
internal final actor FakeRangeFetchClient: RangeFetchClient {
    internal struct Behavior: Sendable {
        var body: Data
        var contentType: String?
        var totalLength: Int64?
        var rangeSupported: Bool
    }

    private var behaviors: [String: Behavior] = [:]
    private var calls: [(url: URL, range: Range<Int64>?)] = []
    private var delayNanoseconds: UInt64 = 0
    private var failAllCalls = false
    private var observedCancellation = false

    internal func setBehavior(url: URL, body: Data, contentType: String? = "video/mp4", totalLength: Int64? = nil, rangeSupported: Bool = true) {
        behaviors[url.absoluteString] = Behavior(
            body: body,
            contentType: contentType,
            totalLength: totalLength,
            rangeSupported: rangeSupported
        )
    }

    internal func setDelay(_ nanoseconds: UInt64) {
        delayNanoseconds = nanoseconds
    }

    internal func enableFailAllCalls() {
        failAllCalls = true
    }

    internal func callCount() -> Int {
        calls.count
    }

    internal func recordedRanges() -> [Range<Int64>?] {
        calls.map(\.range)
    }

    internal func didObserveCancellation() -> Bool {
        observedCancellation
    }

    internal func fetch(url: URL, range: Range<Int64>?) async throws -> RangeFetchResponse {
        calls.append((url, range))
        if failAllCalls {
            throw URLError(.cannotLoadFromNetwork)
        }
        if delayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                observedCancellation = true
                throw error
            }
        }
        try Task.checkCancellation()
        guard let behavior = behaviors[url.absoluteString] else {
            throw URLError(.fileDoesNotExist)
        }
        let total = behavior.totalLength ?? Int64(behavior.body.count)
        if !behavior.rangeSupported {
            let body = behavior.body
            return RangeFetchResponse(
                contentType: behavior.contentType,
                totalLength: total,
                rangeSupported: false,
                chunks: AsyncThrowingStream { continuation in
                    continuation.yield(body)
                    continuation.finish()
                }
            )
        }
        let slice: Data
        if let range {
            let lower = min(Int(range.lowerBound), behavior.body.count)
            let upper = range.upperBound == Int64.max ? behavior.body.count : min(Int(range.upperBound), behavior.body.count)
            slice = lower < upper ? behavior.body.subdata(in: lower ..< upper) : Data()
        } else {
            slice = behavior.body
        }
        return RangeFetchResponse(
            contentType: behavior.contentType,
            totalLength: total,
            rangeSupported: true,
            chunks: AsyncThrowingStream { continuation in
                if !slice.isEmpty {
                    continuation.yield(slice)
                }
                continuation.finish()
            }
        )
    }
}

// MARK: - Helpers

private func testFolder() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("digia-media-cache-test-\(UUID().uuidString)", isDirectory: true)
}

private func patternBody(count: Int) -> Data {
    Data((0 ..< count).map { UInt8($0 % 251) })
}

private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while await !condition() {
        if Date() > deadline {
            return false
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

// MARK: - Contract suite

@Suite("Media range cache contract", .tags(.media, .unit))
struct MediaRangeCacheStoreTests {
    private func makeStore(fake: FakeRangeFetchClient, maxBytes: Int64 = 256 * 1_024 * 1_024) -> (MediaRangeCacheStore, URL) {
        let folder = testFolder()
        return (MediaRangeCacheStore(folder: folder, maxBytes: maxBytes, client: fake), folder)
    }

    private func videoURL(_ name: String = "video.mp4") -> URL {
        URL(string: "https://cdn.example.com/\(name)")!
    }

    @Test("range read stores bytes and serves them")
    func rangeReadStoresBytes() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 256)
        await fake.setBehavior(url: url, body: body)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        let data = try await store.read(url: url, offset: 10, length: 10)

        #expect(data == body.subdata(in: 10 ..< 20))
        #expect(await fake.callCount() == 1)
        #expect(await fake.recordedRanges().first == (10 ..< 20))
    }

    @Test("repeat read of the same range performs zero fetches")
    func repeatReadPerformsZeroFetches() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 256)
        await fake.setBehavior(url: url, body: body)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try await store.read(url: url, offset: 0, length: 64)
        let second = try await store.read(url: url, offset: 0, length: 64)

        #expect(first == second)
        #expect(await fake.callCount() == 1)
    }

    @Test("later range overlapping stored bytes fetches only the gap")
    func laterRangeFetchesOnlyTheGap() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 256)
        await fake.setBehavior(url: url, body: body)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = try await store.read(url: url, offset: 0, length: 100)
        let data = try await store.read(url: url, offset: 0, length: 200)

        #expect(data == body.subdata(in: 0 ..< 200))
        #expect(await fake.callCount() == 2)
        #expect(await fake.recordedRanges().last == (100 ..< 200))
    }

    @Test("gap planner splits stored and missing slices")
    func gapPlannerSplitsSlices() {
        let actions = planCacheActions(requestedOffset: 0, requestedLength: 300, fragments: [0 ..< 100, 200 ..< 300])
        #expect(actions == [
            CacheAction(kind: .local, offset: 0, length: 100),
            CacheAction(kind: .remote, offset: 100, length: 100),
            CacheAction(kind: .local, offset: 200, length: 100),
        ])
    }

    @Test("a gap between two stored ranges is fetched and merged")
    func middleGapIsFetchedAndMerged() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 300)
        await fake.setBehavior(url: url, body: body)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = try await store.read(url: url, offset: 0, length: 100)
        _ = try await store.read(url: url, offset: 200, length: 100)
        let data = try await store.read(url: url, offset: 0, length: 300)

        #expect(data == body.subdata(in: 0 ..< 300))
        #expect(await fake.callCount() == 3)
        #expect(await fake.recordedRanges().last == (100 ..< 200))
    }

    @Test("entry survives a new store instance on the same folder")
    func entrySurvivesNewInstance() async throws {
        let folder = testFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = videoURL()
        let body = patternBody(count: 128)
        let firstFake = FakeRangeFetchClient()
        await firstFake.setBehavior(url: url, body: body)
        let first = MediaRangeCacheStore(folder: folder, client: firstFake)
        _ = try await first.read(url: url, offset: 0, length: 128)

        let failingFake = FakeRangeFetchClient()
        await failingFake.enableFailAllCalls()
        let second = MediaRangeCacheStore(folder: folder, client: failingFake)

        let data = try await second.read(url: url, offset: 0, length: 128)
        #expect(data == body)
    }

    @Test("LRU eviction past the limit drops the least recently served entry")
    func lruEviction() async throws {
        let folder = testFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [videoURL("a.mp4"), videoURL("b.mp4"), videoURL("c.mp4")]
        let firstFake = FakeRangeFetchClient()
        for url in urls {
            await firstFake.setBehavior(url: url, body: patternBody(count: 100))
        }
        let store = MediaRangeCacheStore(folder: folder, maxBytes: 250, client: firstFake)
        for url in urls {
            _ = try await store.read(url: url, offset: 0, length: 100)
        }

        let failingFake = FakeRangeFetchClient()
        await failingFake.enableFailAllCalls()
        let reopened = MediaRangeCacheStore(folder: folder, maxBytes: 250, client: failingFake)
        _ = try await reopened.read(url: urls[1], offset: 0, length: 100)
        _ = try await reopened.read(url: urls[2], offset: 0, length: 100)
        do {
            _ = try await reopened.read(url: urls[0], offset: 0, length: 100)
            Issue.record("oldest entry should have been evicted")
        } catch {
            // Expected: the evicted entry needs the network again.
        }
    }

    @Test("two concurrent readers of one range share a single fetch")
    func concurrentReadersShareOneFetch() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 256)
        await fake.setBehavior(url: url, body: body)
        await fake.setDelay(200_000_000)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        async let first = store.read(url: url, offset: 0, length: 64)
        async let second = store.read(url: url, offset: 0, length: 64)
        let (a, b) = try await (first, second)

        #expect(a == body.subdata(in: 0 ..< 64))
        #expect(b == body.subdata(in: 0 ..< 64))
        #expect(await fake.callCount() == 1)
    }

    @Test("server without Range support falls back to a whole-file save")
    func noRangeFallbackSavesWholeFile() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 100)
        await fake.setBehavior(url: url, body: body, totalLength: 100, rangeSupported: false)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try await store.read(url: url, offset: 10, length: 10)
        let second = try await store.read(url: url, offset: 30, length: 10)

        #expect(first == body.subdata(in: 10 ..< 20))
        #expect(second == body.subdata(in: 30 ..< 40))
        #expect(await fake.callCount() == 1)
    }

    @Test("cancelling a read cancels its fetch")
    func cancelledReadCancelsFetch() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        await fake.setBehavior(url: url, body: patternBody(count: 256))
        await fake.setDelay(60_000_000_000)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        let task = Task { try await store.read(url: url, offset: 0, length: 64) }
        #expect(await waitUntil { await fake.callCount() == 1 })
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled read should throw")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await fake.didObserveCancellation())
    }

    @Test("process-wide one store per folder")
    func sharedStorePerFolder() async {
        let folder = testFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = MediaRangeCacheStore.shared(folder: folder)
        let second = MediaRangeCacheStore.shared(folder: folder)
        #expect(first === second)
        #expect(MediaRangeCacheStore.shared(folder: testFolder()) !== first)
    }

    @Test("read past a known end finishes empty without fetching")
    func outOfRangeReadFinishesEmpty() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 100)
        await fake.setBehavior(url: url, body: body, totalLength: 100)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = try await store.read(url: url, offset: 0, length: 10)
        let data = try await store.read(url: url, offset: 200, length: 10)

        #expect(data.isEmpty)
        #expect(await fake.callCount() == 1)
    }

    @Test("index merges adjacent fragments into one")
    func indexMergesAdjacentFragments() {
        var index = RangeIndexStore()
        index.addFragment(offset: 0, length: 100)
        index.addFragment(offset: 100, length: 50)
        index.addFragment(offset: 300, length: 10)

        #expect(index.fragments.count == 2)
        #expect(index.fragments.first == RangeFragment(offset: 0, length: 150))
    }

    @Test("recording content info never truncates stored bytes")
    func contentInfoNeverTruncates() {
        let folder = testFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = CachedMediaFile(dataURL: folder.appendingPathComponent("clip.media"))
        let bytes = patternBody(count: 100)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! file.write(bytes, at: 0)
        file.updateContentInfo(MediaContentInfo(contentType: "public.mpeg-4", contentLength: 50, byteRangeAccessSupported: true))

        #expect(file.index.contentInfo?.contentLength == 50)
        #expect(file.read(offset: 0, length: 100) == bytes)
    }

    @Test("content-range total parsing")
    func parsesContentRangeTotal() {
        #expect(parseTotalLength(fromContentRange: "bytes 0-99/1234") == 1234)
        #expect(parseTotalLength(fromContentRange: "bytes */1234") == 1234)
        #expect(parseTotalLength(fromContentRange: nil) == nil)
        #expect(parseTotalLength(fromContentRange: "bytes 0-99/*") == nil)
    }

    @Test("fetchable MIME gate rejects page markup")
    func mimeGateRejectsMarkup() {
        #expect(isCacheable(mimeType: "video/mp4"))
        #expect(isCacheable(mimeType: "application/octet-stream"))
        #expect(isCacheable(mimeType: nil))
        #expect(!isCacheable(mimeType: "text/html"))
    }

    @Test("MIME type maps to the AVFoundation UTI")
    func mimeTypeMapsToUTI() {
        #expect(mediaCacheUTI(forMimeType: "video/mp4") == "public.mpeg-4")
        #expect(mediaCacheUTI(forMimeType: nil) == "public.data")
    }
}
