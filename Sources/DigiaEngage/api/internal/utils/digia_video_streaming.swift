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

    private struct QueuedDownload {
        let remoteURL: URL
        var priority: StoryVideoCachePriority
        let order: UInt64
        var waiters: [CheckedContinuation<URL, Error>]
    }

    private struct ActiveDownload {
        let remoteURL: URL
        var waiters: [CheckedContinuation<URL, Error>]
    }

    private let session: URLSession
    private let directory: URL
    private let maxBytes: Int64
    private var queued: [String: QueuedDownload] = [:]
    private var active: [String: ActiveDownload] = [:]
    private var failedAt: [String: Date] = [:]
    private var nextOrder: UInt64 = 0

    init(
        session: URLSession = .shared,
        directory: URL? = nil,
        maxBytes: Int64 = defaultLimitBytes
    ) {
        self.session = session
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tech.digia.engage.video", isDirectory: true)
        self.maxBytes = max(maxBytes, 1)
    }

    func cachedURL(for remoteURL: URL) -> URL? {
        usableCachedURL(for: remoteURL, touch: true)
    }

    func localURL(
        for remoteURL: URL,
        priority: StoryVideoCachePriority
    ) async throws -> URL {
        if let cached = usableCachedURL(for: remoteURL, touch: true) {
            return cached
        }
        let key = Self.key(for: remoteURL)
        if isCoolingDown(key) {
            throw URLError(.cannotLoadFromNetwork)
        }

        return try await withCheckedThrowingContinuation { continuation in
            enqueue(
                remoteURL,
                priority: priority,
                waiter: continuation,
                startImmediately: true
            )
        }
    }

    /// Adds demand in Campaign order. This returns after queueing; downloads intentionally outlive
    /// a rail render so scrolling cannot repeatedly cancel and restart the same network request.
    func prepare(_ demands: [StoryVideoCacheDemand]) {
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
        for key in order {
            guard let demand = strongestByKey[key] else { continue }
            enqueue(
                demand.url,
                priority: demand.priority,
                waiter: nil,
                startImmediately: false
            )
        }
        startDownloadsIfPossible()
    }

    private func enqueue(
        _ remoteURL: URL,
        priority: StoryVideoCachePriority,
        waiter: CheckedContinuation<URL, Error>?,
        startImmediately: Bool
    ) {
        if let cached = usableCachedURL(for: remoteURL, touch: true) {
            waiter?.resume(returning: cached)
            return
        }

        let key = Self.key(for: remoteURL)
        if isCoolingDown(key) {
            waiter?.resume(throwing: URLError(.cannotLoadFromNetwork))
            return
        }
        if var download = active[key] {
            if let waiter { download.waiters.append(waiter) }
            active[key] = download
            return
        }
        if var download = queued[key] {
            download.priority = max(download.priority, priority)
            if let waiter { download.waiters.append(waiter) }
            queued[key] = download
        } else {
            nextOrder &+= 1
            queued[key] = QueuedDownload(
                remoteURL: remoteURL,
                priority: priority,
                order: nextOrder,
                waiters: waiter.map { [$0] } ?? []
            )
        }
        if startImmediately {
            startDownloadsIfPossible()
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
                    var request = URLRequest(url: download.remoteURL)
                    // The SDK cache is the sole persistent copy of this multi-megabyte response.
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    let result = try await session.download(for: request)
                    finishDownload(key: key, result: .success(result))
                } catch {
                    finishDownload(key: key, result: .failure(error))
                }
            }
        }
    }

    private func finishDownload(
        key: String,
        result: Result<(URL, URLResponse), Error>
    ) {
        guard let download = active.removeValue(forKey: key) else { return }
        do {
            let localURL: URL
            switch result {
            case let .success((temporaryURL, response)):
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                localURL = try publish(
                    temporaryURL,
                    remoteURL: download.remoteURL,
                    expectedBytes: response.expectedContentLength
                )
            case let .failure(error):
                throw error
            }
            failedAt[key] = nil
            download.waiters.forEach { $0.resume(returning: localURL) }
        } catch {
            failedAt[key] = Date()
            download.waiters.forEach { $0.resume(throwing: error) }
        }
        startDownloadsIfPossible()
    }

    private func publish(
        _ downloadedURL: URL,
        remoteURL: URL,
        expectedBytes: Int64
    ) throws -> URL {
        let fileManager = FileManager.default
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
        guard expectedBytes < 0 || downloadedBytes == expectedBytes else {
            throw URLError(.cannotDecodeContentData)
        }

        let staged = directory.appendingPathComponent(".\(key)-\(UUID().uuidString).partial")
        defer { try? fileManager.removeItem(at: staged) }
        do {
            try fileManager.moveItem(at: downloadedURL, to: staged)
        } catch {
            try fileManager.copyItem(at: downloadedURL, to: staged)
            try? fileManager.removeItem(at: downloadedURL)
        }
        guard try Self.fileSize(staged) == downloadedBytes else {
            throw URLError(.cannotDecodeContentData)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        // The staging file is in the cache directory, so this final rename is atomic.
        try fileManager.moveItem(at: staged, to: destination)
        Self.touch(destination)
        evictOldFiles(keeping: destination)
        return destination
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

    private func evictOldFiles(keeping: URL) {
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
        for (url, size, _) in files where totalBytes > maxBytes && url != keeping {
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            totalBytes -= size
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
