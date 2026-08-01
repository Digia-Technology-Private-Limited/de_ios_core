import CryptoKit
import Foundation
#if DEBUG
import AVFoundation
#endif

enum StoryVideoCachePriority: Int, Comparable, Sendable {
    case lookAhead
    case eligible
    case scheduled
    case fullScreen

    static func < (lhs: StoryVideoCachePriority, rhs: StoryVideoCachePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct StoryVideoCacheDemand: Hashable, Sendable {
    let url: URL
    let priority: StoryVideoCachePriority
}

/// Process-wide persistent cache for progressive story videos.
///
/// The exact remote URL is the cache identity. At most two distinct URLs are downloaded at once;
/// repeated demand joins the same queued or active download. File publication and LRU eviction run
/// on this actor, so a player can never observe a partially written cache entry.
actor DigiaVideoFileCache {
    static let shared = DigiaVideoFileCache()

    private static let defaultLimitBytes: Int64 = 256 * 1_024 * 1_024
    private static let failedDownloadRetryInterval: TimeInterval = 5 * 60
    private static let maximumActiveDownloads = 2
    private static let writeBufferBytes = 64 * 1_024
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private struct QueuedDownload {
        let remoteURL: URL
        let order: UInt64
        var demandPriorities: [UUID: StoryVideoCachePriority]
        var waiters: [UUID: DownloadWaiter]

        var priority: StoryVideoCachePriority {
            (Array(demandPriorities.values) + waiters.values.map(\.priority)).max() ?? .lookAhead
        }

        var isNeeded: Bool {
            !demandPriorities.isEmpty || !waiters.isEmpty
        }
    }

    private struct DownloadWaiter {
        let priority: StoryVideoCachePriority
        let continuation: CheckedContinuation<URL, Error>
    }

    private struct ActiveDownload {
        let remoteURL: URL
        var waiters: [UUID: DownloadWaiter]
    }

    private let session: URLSession
    private let directory: URL
    private let maxBytes: Int64
    private var queued: [String: QueuedDownload] = [:]
    private var active: [String: ActiveDownload] = [:]
    private var failedAt: [String: Date] = [:]
    private var nextOrder: UInt64 = 0
    private var directoryPrepared = false

    init(
        session: URLSession? = nil,
        directory: URL? = nil,
        maxBytes: Int64 = defaultLimitBytes
    ) {
        self.session = session ?? Self.defaultSession
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tech.digia.engage.video", isDirectory: true)
        self.maxBytes = max(maxBytes, 1)
    }

    func cachedURL(for remoteURL: URL) -> URL? {
        prepareDirectoryIfNeeded()
        return usableCachedURL(for: remoteURL, touch: true)
    }

    func peekCachedURL(for remoteURL: URL) -> URL? {
        prepareDirectoryIfNeeded()
        return usableCachedURL(for: remoteURL, touch: false)
    }

    func localURL(
        for remoteURL: URL,
        priority: StoryVideoCachePriority
    ) async throws -> URL {
        try Task.checkCancellation()
        prepareDirectoryIfNeeded()
        if let cached = usableCachedURL(for: remoteURL, touch: priority != .lookAhead) {
            return cached
        }
        let key = Self.key(for: remoteURL)
        if isCoolingDown(key) {
            throw URLError(.cannotLoadFromNetwork)
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    remoteURL,
                    priority: priority,
                    waiterID: waiterID,
                    waiter: continuation,
                    demandOwner: nil,
                    startImmediately: true
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, key: key) }
        }
    }

    /// Replaces one rail's demand snapshot. Transfers already in progress finish and populate the
    /// cache; stale work that has not started is removed once no rail or awaiting player needs it.
    func prepare(_ demands: [StoryVideoCacheDemand], owner: UUID) {
        prepareDirectoryIfNeeded()
        var order: [String] = []
        var strongestByKey: [String: StoryVideoCacheDemand] = [:]
        for demand in demands {
            let key = Self.key(for: demand.url)
            if let existing = strongestByKey[key] {
                if demand.priority > existing.priority {
                    strongestByKey[key] = demand
                }
            } else {
                order.append(key)
                strongestByKey[key] = demand
            }
        }

        removeQueuedDemand(for: owner)
        for key in order {
            guard let demand = strongestByKey[key] else { continue }
            enqueue(
                demand.url,
                priority: demand.priority,
                waiterID: nil,
                waiter: nil,
                demandOwner: owner,
                startImmediately: false
            )
        }
        startDownloadsIfPossible()
    }

    func clearDemand(owner: UUID) {
        removeQueuedDemand(for: owner)
        startDownloadsIfPossible()
    }

    private func enqueue(
        _ remoteURL: URL,
        priority: StoryVideoCachePriority,
        waiterID: UUID?,
        waiter: CheckedContinuation<URL, Error>?,
        demandOwner: UUID?,
        startImmediately: Bool
    ) {
        if let cached = usableCachedURL(for: remoteURL, touch: priority != .lookAhead) {
            waiter?.resume(returning: cached)
            return
        }

        let key = Self.key(for: remoteURL)
        if isCoolingDown(key) {
            waiter?.resume(throwing: URLError(.cannotLoadFromNetwork))
            return
        }
        if var download = active[key] {
            if let waiterID, let waiter {
                download.waiters[waiterID] = DownloadWaiter(
                    priority: priority,
                    continuation: waiter
                )
            }
            active[key] = download
            return
        }
        if var download = queued[key] {
            if let demandOwner { download.demandPriorities[demandOwner] = priority }
            if let waiterID, let waiter {
                download.waiters[waiterID] = DownloadWaiter(
                    priority: priority,
                    continuation: waiter
                )
            }
            queued[key] = download
        } else {
            nextOrder &+= 1
            queued[key] = QueuedDownload(
                remoteURL: remoteURL,
                order: nextOrder,
                demandPriorities: demandOwner.map { [$0: priority] } ?? [:],
                waiters: waiterID.flatMap { id in
                    waiter.map { [id: DownloadWaiter(priority: priority, continuation: $0)] }
                } ?? [:]
            )
        }
        if startImmediately {
            startDownloadsIfPossible()
        }
    }

    private func removeQueuedDemand(for owner: UUID) {
        for key in Array(queued.keys) {
            guard var download = queued[key] else { continue }
            download.demandPriorities[owner] = nil
            queued[key] = download.isNeeded ? download : nil
        }
    }

    private func cancelWaiter(_ waiterID: UUID, key: String) {
        if var download = queued[key],
           let waiter = download.waiters.removeValue(forKey: waiterID) {
            waiter.continuation.resume(throwing: CancellationError())
            queued[key] = download.isNeeded ? download : nil
            startDownloadsIfPossible()
            return
        }
        if var download = active[key],
           let waiter = download.waiters.removeValue(forKey: waiterID) {
            waiter.continuation.resume(throwing: CancellationError())
            active[key] = download
        }
    }

    private func startDownloadsIfPossible() {
        while active.count < Self.maximumActiveDownloads,
              let next = queued.min(by: { lhs, rhs in
                  if lhs.value.priority != rhs.value.priority {
                      return lhs.value.priority > rhs.value.priority
                  }
                  return lhs.value.order < rhs.value.order
              })
        {
            let key = next.key
            let download = next.value
            queued[key] = nil
            active[key] = ActiveDownload(
                remoteURL: download.remoteURL,
                waiters: download.waiters
            )
            let session = session
            Task {
                do {
                    let temporaryURL = try await Self.download(
                        remoteURL: download.remoteURL,
                        key: key,
                        session: session,
                        directory: directory,
                        maxBytes: maxBytes
                    )
                    finishDownload(key: key, result: .success(temporaryURL))
                } catch {
                    finishDownload(key: key, result: .failure(error))
                }
            }
        }
    }

    private func finishDownload(
        key: String,
        result: Result<URL, Error>
    ) {
        guard let download = active.removeValue(forKey: key) else { return }
        do {
            let localURL: URL
            switch result {
            case let .success(temporaryURL):
                localURL = try publish(temporaryURL, remoteURL: download.remoteURL)
            case let .failure(error):
                throw error
            }
            failedAt[key] = nil
            download.waiters.values.forEach { $0.continuation.resume(returning: localURL) }
        } catch {
            failedAt[key] = Date()
            download.waiters.values.forEach { $0.continuation.resume(throwing: error) }
        }
        startDownloadsIfPossible()
    }

    private func publish(
        _ downloadedURL: URL,
        remoteURL: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        var published = false
        defer {
            if !published { try? fileManager.removeItem(at: downloadedURL) }
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let key = Self.key(for: remoteURL)
        let destination = directory.appendingPathComponent(
            Self.fileName(for: remoteURL, key: key)
        )
        if let cached = usableCachedURL(for: remoteURL, touch: true) {
            try? fileManager.removeItem(at: downloadedURL)
            return cached
        }

        let downloadedBytes = try Self.fileSize(downloadedURL)
        guard downloadedBytes > 0, downloadedBytes <= maxBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        // The completed partial is in this directory, so publication is one atomic rename.
        try fileManager.moveItem(at: downloadedURL, to: destination)
        published = true
        Self.touch(destination)
        evictOldFiles(keeping: destination)
        return destination
    }

    private func prepareDirectoryIfNeeded() {
        guard !directoryPrepared else { return }
        directoryPrepared = true
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for file in files where file.lastPathComponent.hasSuffix(".partial") {
                try? fileManager.removeItem(at: file)
            }
        }
        evictOldFiles()
    }

    private func usableCachedURL(for remoteURL: URL, touch: Bool) -> URL? {
        let destination = directory.appendingPathComponent(
            Self.fileName(for: remoteURL, key: Self.key(for: remoteURL))
        )
        guard let size = try? Self.fileSize(destination),
              size > 0,
              size <= maxBytes else {
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            return nil
        }
        failedAt[Self.key(for: remoteURL)] = nil
        if touch { Self.touch(destination) }
        return destination
    }

    private func isCoolingDown(_ key: String) -> Bool {
        guard let lastFailure = failedAt[key] else { return false }
        return Date().timeIntervalSince(lastFailure) < Self.failedDownloadRetryInterval
    }

    private func evictOldFiles(keeping: URL? = nil) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var files = urls.compactMap { url -> (URL, Int64, Date)? in
            guard !url.lastPathComponent.hasSuffix(".partial"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var totalBytes = files.reduce(Int64(0)) { $0 + $1.1 }
        files.sort { $0.2 < $1.2 }
        for (url, size, _) in files where totalBytes > maxBytes {
            if let keeping, url == keeping { continue }
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            totalBytes -= size
        }
    }

    private static func download(
        remoteURL: URL,
        key: String,
        session: URLSession,
        directory: URL,
        maxBytes: Int64
    ) async throws -> URL {
        var request = URLRequest(url: remoteURL)
        // The SDK cache is the sole persistent copy of this multi-megabyte response.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        let expectedBytes = response.expectedContentLength
        guard expectedBytes < 0 || expectedBytes <= maxBytes else {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }

        let partial = directory.appendingPathComponent(".\(key)-\(UUID().uuidString).partial")
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            bytes.task.cancel()
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(writeBufferBytes)
            var receivedBytes: Int64 = 0

            for try await byte in bytes {
                try Task.checkCancellation()
                receivedBytes += 1
                guard receivedBytes <= maxBytes else {
                    bytes.task.cancel()
                    throw URLError(.dataLengthExceedsMaximum)
                }
                buffer.append(byte)
                if buffer.count >= writeBufferBytes {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            try handle.synchronize()
            guard receivedBytes > 0,
                  expectedBytes < 0 || receivedBytes == expectedBytes else {
                throw URLError(.cannotDecodeContentData)
            }
            return partial
        } catch {
            bytes.task.cancel()
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func fileName(for url: URL, key: String) -> String {
        let candidate = url.pathExtension
        let isSafe = !candidate.isEmpty
            && candidate.count <= 8
            && candidate.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        return "\(key).\(isSafe ? candidate : "video")"
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { return 0 }
        return Int64(values.fileSize ?? 0)
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }
}

#if DEBUG
// Kept only so the unchanged legacy test target can compile while this MR removes the old
// resource-loader implementation. Production playback always uses the local cached file.
enum DigiaVideoStreaming {
    static func makeAsset(for url: URL) -> AVURLAsset {
        AVURLAsset(url: url)
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov": "video/quicktime"
        case "m4v": "video/x-m4v"
        default: "video/mp4"
        }
    }
}

enum DigiaStreamingResourceLoaderDelegate {
    struct ContentRange {
        let start: Int64
        let total: Int64
    }

    static func contentRange(from response: HTTPURLResponse) -> ContentRange? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let components = value.split(separator: " ", maxSplits: 1)
        guard components.count == 2, components[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = components[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2,
              let total = Int64(rangeAndTotal[1]),
              let startPart = rangeAndTotal[0].split(separator: "-", maxSplits: 1).first,
              let start = Int64(startPart) else { return nil }
        return ContentRange(start: start, total: total)
    }

    static func payload(
        from data: Data,
        responseStart: Int64,
        requestedStart: Int64,
        requestedLength: Int?
    ) -> Data? {
        let relativeStart = requestedStart - responseStart
        guard relativeStart >= 0, relativeStart <= Int64(data.count) else { return nil }
        let lowerBound = Int(relativeStart)
        let upperBound = requestedLength.map { min(lowerBound + $0, data.count) } ?? data.count
        guard upperBound > lowerBound else { return nil }
        return data.subdata(in: lowerBound..<upperBound)
    }
}
#endif
