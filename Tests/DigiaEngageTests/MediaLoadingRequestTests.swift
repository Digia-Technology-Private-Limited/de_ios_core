import AVFoundation
import Foundation
import Testing
@testable import DigiaEngage

// MARK: - Fake

/// Fake loading request: records content-info fills, streamed chunks, and the
/// terminal finish, behind a lock so worker Task threads can touch it.
internal final class FakeLoadingRequest: MediaLoadingRequest, @unchecked Sendable {
    internal let requestedOffset: Int64
    internal let requestedLength: Int
    internal let requestsAllDataToEnd: Bool
    internal var requestID: AnyObject { self }

    private let lock = NSLock()
    private var fills: [(contentType: String?, contentLength: Int64, byteRangeSupported: Bool)] = []
    private var chunks: [Data] = []
    private var finished = false
    private var finishError: NSError?

    internal init(offset: Int64 = 0, length: Int = 0, toEnd: Bool = false) {
        self.requestedOffset = offset
        self.requestedLength = length
        self.requestsAllDataToEnd = toEnd
    }

    internal func fillContentInfo(contentType: String?, contentLength: Int64, byteRangeSupported: Bool) {
        lock.lock()
        defer { lock.unlock() }
        fills.append((contentType, contentLength, byteRangeSupported))
    }

    internal func respond(with data: Data) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(data)
    }

    internal func finish(error: NSError?) {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        finishError = error
    }

    internal var recordedFills: [(contentType: String?, contentLength: Int64, byteRangeSupported: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return fills
    }

    internal var receivedBytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return chunks.reduce(Data(), +)
    }

    internal var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    internal var terminalError: NSError? {
        lock.lock()
        defer { lock.unlock() }
        return finishError
    }
}

// MARK: - Helpers

private func testFolder() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("digia-media-loader-test-\(UUID().uuidString)", isDirectory: true)
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

// MARK: - Suite

@Suite("Media loading request", .tags(.media, .unit))
struct MediaLoadingRequestTests {
    private func makeStore(fake: FakeRangeFetchClient) -> (MediaRangeCacheStore, URL) {
        let folder = testFolder()
        return (MediaRangeCacheStore(folder: folder, client: fake), folder)
    }

    private func videoURL() -> URL {
        URL(string: "https://cdn.example.com/video.mp4")!
    }

    @Test("worker fills content info and streams data before finishing")
    func workerServesRange() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 256)
        await fake.setBehavior(url: url, body: body, totalLength: 256)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = FakeLoadingRequest(offset: 10, length: 20)
        let worker = LoadingRequestWorker(store: store, url: url, request: request)
        await worker.start().value

        let fills = request.recordedFills
        #expect(!fills.isEmpty)
        #expect(fills.first?.contentLength == 256)
        #expect(fills.first?.byteRangeSupported == true)
        #expect(request.receivedBytes == body.subdata(in: 10 ..< 30))
        #expect(request.isFinished)
        #expect(request.terminalError == nil)
    }

    @Test("worker serves requestsAllDataToEndOfResource as an open-ended fetch when the total is unknown")
    func workerToEndUnknownLength() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 120)
        await fake.setBehavior(url: url, body: body, totalLength: nil)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = FakeLoadingRequest(offset: 20, toEnd: true)
        let worker = LoadingRequestWorker(store: store, url: url, request: request)
        await worker.start().value

        #expect(request.receivedBytes == body.subdata(in: 20 ..< 120))
        #expect(request.isFinished)
        let ranges = await fake.recordedRanges()
        #expect(ranges.count == 1)
        #expect(ranges.first??.lowerBound == 20)
    }

    @Test("worker clamps requestsAllDataToEndOfResource to a bounded range when the total is known")
    func workerToEndKnownLength() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 100)
        await fake.setBehavior(url: url, body: body, totalLength: 100)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        let priming = FakeLoadingRequest(offset: 0, length: 10)
        await LoadingRequestWorker(store: store, url: url, request: priming).start().value

        let request = FakeLoadingRequest(offset: 90, toEnd: true)
        await LoadingRequestWorker(store: store, url: url, request: request).start().value

        #expect(request.receivedBytes == body.subdata(in: 90 ..< 100))
        let ranges = await fake.recordedRanges()
        #expect(ranges.last == (90 ..< 100))
    }

    @Test("cancelling a worker cancels its fetch and finishes the request as cancelled")
    func workerCancellation() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        await fake.setBehavior(url: url, body: patternBody(count: 256), totalLength: 256)
        await fake.setDelay(60_000_000_000)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = FakeLoadingRequest(offset: 0, length: 64)
        let worker = LoadingRequestWorker(store: store, url: url, request: request)
        let task = worker.start()
        #expect(await waitUntil { await fake.callCount() == 1 })
        worker.cancel()
        await task.value

        #expect(request.isFinished)
        #expect((request.terminalError as? URLError)?.code == .cancelled)
        #expect(await fake.didObserveCancellation())
    }

    @Test("loader serves two requests and goes idle when both finish")
    func loaderServesTwoRequests() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        let body = patternBody(count: 256)
        await fake.setBehavior(url: url, body: body, totalLength: 256)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        let queue = DispatchQueue(label: "digia.media.loader.test.\(UUID().uuidString)")
        let loader = URLAssetLoader(url: url, store: store, queue: queue)
        let first = FakeLoadingRequest(offset: 0, length: 32)
        let second = FakeLoadingRequest(offset: 32, length: 32)
        let firstTask = loader.add(first)
        let secondTask = loader.add(second)
        await firstTask.value
        await secondTask.value

        #expect(first.receivedBytes == body.subdata(in: 0 ..< 32))
        #expect(second.receivedBytes == body.subdata(in: 32 ..< 64))
        #expect(first.isFinished && second.isFinished)
        #expect(await waitUntil { loader.isIdle })
    }

    @Test("removing a request cancels it without touching the other one")
    func loaderRemoveCancelsOne() async throws {
        let fake = FakeRangeFetchClient()
        let url = videoURL()
        await fake.setBehavior(url: url, body: patternBody(count: 256), totalLength: 256)
        await fake.setDelay(60_000_000_000)
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }

        let queue = DispatchQueue(label: "digia.media.loader.test.\(UUID().uuidString)")
        let loader = URLAssetLoader(url: url, store: store, queue: queue)
        let doomed = FakeLoadingRequest(offset: 0, length: 64)
        let task = loader.add(doomed)
        #expect(await waitUntil { await fake.callCount() == 1 })
        loader.remove(doomed)
        await task.value

        #expect(doomed.isFinished)
        #expect((doomed.terminalError as? URLError)?.code == .cancelled)
        #expect(await fake.didObserveCancellation())
    }

    @Test("asset URL wraps and recovers the origin URL")
    func assetURLRoundTrip() {
        let origins = [
            "https://cdn.example.com/video.mp4",
            "https://cdn.example.com:8443/a/b.mp4?token=x%20y&n=1#frag",
        ]
        for absolute in origins {
            let origin = URL(string: absolute)!
            let asset = MediaResourceLoader.assetURL(for: origin)
            #expect(asset != nil)
            #expect(asset?.scheme == MediaResourceLoader.scheme)
            #expect(MediaResourceLoader.originURL(from: asset!) == origin)
        }
        #expect(MediaResourceLoader.originURL(from: URL(string: "https://cdn.example.com/a.mp4")!) == nil)
    }

    @Test("manager builds a cache-backed player item")
    func playerItemFactory() {
        let fake = FakeRangeFetchClient()
        let (store, folder) = makeStore(fake: fake)
        defer { try? FileManager.default.removeItem(at: folder) }
        let loader = MediaResourceLoader(store: store)

        let item = loader.playerItem(for: videoURL())

        #expect(item != nil)
        #expect((item?.asset as? AVURLAsset)?.url.scheme == MediaResourceLoader.scheme)
    }
}
