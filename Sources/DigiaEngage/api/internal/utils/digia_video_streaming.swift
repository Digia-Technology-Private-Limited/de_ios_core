import AVFoundation
import CryptoKit
import Foundation

// MARK: - Persistent progressive-video cache

/// Stores each remote MP4 once and gives every thumbnail/full-screen player the
/// same local file. AVPlayer's range buffering is not a persistent download
/// cache, so recreating players can otherwise create many requests for one URL.
actor DigiaVideoFileCache {
    static let shared = DigiaVideoFileCache()

    private static let defaultLimitBytes: Int64 = 256 * 1_024 * 1_024
    private static let failedDownloadRetryInterval: TimeInterval = 5 * 60

    private let session: URLSession
    private let directory: URL
    private let maxBytes: Int64
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var failedAt: [String: Date] = [:]

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

    func localURL(for remoteURL: URL) async throws -> URL {
        let key = Self.key(for: remoteURL)
        let destination = directory.appendingPathComponent(
            Self.fileName(for: remoteURL, key: key)
        )
        if Self.isUsableFile(destination, maxBytes: maxBytes) {
            failedAt[key] = nil
            Self.touch(destination)
            return destination
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }
        if let lastFailure = failedAt[key],
           Date().timeIntervalSince(lastFailure) < Self.failedDownloadRetryInterval {
            throw URLError(.cannotLoadFromNetwork)
        }

        let session = session
        let directory = directory
        let maxBytes = maxBytes
        let task = Task<URL, Error> {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            var request = URLRequest(url: remoteURL)
            // This directory is the source of truth. Avoid creating another
            // opaque URLCache copy of the same multi-megabyte response.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (temporaryURL, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            guard Self.isUsableFile(temporaryURL, maxBytes: maxBytes) else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            if Self.isUsableFile(destination, maxBytes: maxBytes) {
                try? fileManager.removeItem(at: temporaryURL)
                return destination
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporaryURL, to: destination)
            Self.touch(destination)
            Self.evictOldFiles(
                in: directory,
                keeping: destination,
                maxBytes: maxBytes
            )
            return destination
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let result = try await task.value
            failedAt[key] = nil
            return result
        } catch {
            failedAt[key] = Date()
            throw error
        }
    }

    func prefetch(_ remoteURLs: [URL], maxConcurrent: Int = 4) async {
        let uniqueURLs = Array(Set(remoteURLs))
        let batchSize = max(maxConcurrent, 1)
        for start in stride(from: 0, to: uniqueURLs.count, by: batchSize) {
            let end = min(start + batchSize, uniqueURLs.count)
            await withTaskGroup(of: Void.self) { group in
                for url in uniqueURLs[start..<end] {
                    group.addTask {
                        _ = try? await self.localURL(for: url)
                    }
                }
            }
        }
    }

    private static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func fileName(for url: URL, key: String) -> String {
        let pathExtension = url.pathExtension.isEmpty ? "video" : url.pathExtension
        return "\(key).\(pathExtension)"
    }

    private static func isUsableFile(_ url: URL, maxBytes: Int64) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        let size = Int64(values.fileSize ?? 0)
        return values.isRegularFile == true && size > 0 && size <= maxBytes
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    private static func evictOldFiles(in directory: URL, keeping: URL, maxBytes: Int64) {
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
            guard let values = try? url.resourceValues(forKeys: keys),
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
}

// MARK: - Playback with a forced content type (ExoPlayer parity)

/// Builds AVURLAssets for remote videos whose HTTP `Content-Type` isn't a video
/// MIME type.
///
/// AVPlayer trusts the server's `Content-Type` to decide an asset's format, so a
/// host like `raw.githubusercontent.com` — which serves `.mp4` as
/// `application/octet-stream` with `X-Content-Type-Options: nosniff` — makes
/// AVFoundation refuse to play, even though the same URL plays on Android.
/// Android's ExoPlayer ignores `Content-Type` and sniffs the container instead.
///
/// On iOS 17 and newer, `AVURLAssetOverrideMIMETypeKey` gives us that parity
/// while AVFoundation retains ownership of redirects, ranges, cancellation and
/// streaming. Older systems use the resource-loader compatibility path below.
enum DigiaVideoStreaming {
    // Only used for its stable address as an associated-object key; never read
    // or mutated as a value, so unchecked concurrency access is safe.
    nonisolated(unsafe) private static var delegateKey: UInt8 = 0

    static func makeAsset(for url: URL) -> AVURLAsset {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return AVURLAsset(url: url)
        }

        if #available(iOS 17, *) {
            return AVURLAsset(
                url: url,
                options: [AVURLAssetOverrideMIMETypeKey: mimeType(for: url)]
            )
        }

        // Swap the scheme to a custom one so AVFoundation hands all loading to
        // our iOS 15/16 compatibility delegate instead of trying (and failing)
        // to play it directly.
        components.scheme = DigiaStreamingResourceLoaderDelegate.scheme
        guard let proxyURL = components.url else { return AVURLAsset(url: url) }

        let asset = AVURLAsset(url: proxyURL)
        let delegate = DigiaStreamingResourceLoaderDelegate(originalURL: url)
        asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue(label: "tech.digia.video.resourceloader"))
        // `setDelegate` does not retain the delegate, so tie its lifetime to the
        // asset's.
        objc_setAssociatedObject(asset, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov": "video/quicktime"
        case "m4v": "video/x-m4v"
        default: "video/mp4"
        }
    }
}

/// Streams a remote video via HTTP byte-range requests and reports a forced
/// content type, so AVPlayer plays sources whose `Content-Type` isn't a video
/// MIME type. Mirrors Android's ExoPlayer (container sniffing + progressive
/// streaming). See `DigiaVideoStreaming`.
final class DigiaStreamingResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate,
    @unchecked Sendable
{
    static let scheme = "digiastream"

    private let originalURL: URL
    private let contentTypeUTI: String
    private let session = URLSession(configuration: .default)
    private let taskLock = NSLock()
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(originalURL: URL) {
        self.originalURL = originalURL
        switch originalURL.pathExtension.lowercased() {
        case "mov": contentTypeUTI = "com.apple.quicktime-movie"
        case "m4v": contentTypeUTI = "com.apple.m4v-video"
        default: contentTypeUTI = "public.mpeg-4"
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        var request = URLRequest(url: originalURL)
        let requestID = ObjectIdentifier(loadingRequest)
        let requestedStart: Int64
        let requestedLength: Int?

        if let dataRequest = loadingRequest.dataRequest {
            // AVFoundation may already have consumed part of a request. Asking
            // again from requestedOffset returns duplicate bytes and can make
            // the parser repeatedly request the same range.
            let start = dataRequest.currentOffset
            let consumed = max(start - dataRequest.requestedOffset, 0)
            let remaining = max(dataRequest.requestedLength - Int(consumed), 0)
            requestedStart = start
            requestedLength = dataRequest.requestsAllDataToEndOfResource ? nil : remaining

            if dataRequest.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            } else {
                guard remaining > 0 else {
                    loadingRequest.finishLoading()
                    return true
                }
                let end = start + Int64(remaining) - 1
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            }
        } else {
            requestedStart = 0
            requestedLength = 0
            // A content-information-only request should not download the
            // entire video on the compatibility path.
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: request) { [weak self, contentTypeUTI] data, response, error in
            self?.removeTask(for: requestID)
            guard !loadingRequest.isCancelled else { return }

            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                loadingRequest.finishLoading(with: Self.httpError(status: status))
                return
            }

            let contentRange = Self.contentRange(from: http)
            if http.statusCode == 206, contentRange == nil {
                loadingRequest.finishLoading(with: Self.invalidRangeError())
                return
            }
            if http.statusCode == 200, requestedStart > 0 {
                // The server ignored a non-zero Range header. Passing bytes
                // from offset zero as if they began at requestedStart corrupts
                // AVFoundation's parser state and causes an endless retry loop.
                loadingRequest.finishLoading(with: Self.invalidRangeError())
                return
            }

            if let info = loadingRequest.contentInformationRequest {
                info.contentType = contentTypeUTI
                info.isByteRangeAccessSupported = http.statusCode == 206
                let totalLength = contentRange?.total ?? http.expectedContentLength
                if totalLength >= 0 {
                    info.contentLength = totalLength
                }
            }

            if let dataRequest = loadingRequest.dataRequest,
               let data,
               let responseStart = contentRange?.start ?? (http.statusCode == 200 ? 0 : nil),
               let payload = Self.payload(
                   from: data,
                   responseStart: responseStart,
                   requestedStart: requestedStart,
                   requestedLength: requestedLength
               ) {
                dataRequest.respond(with: payload)
            } else if loadingRequest.dataRequest != nil {
                loadingRequest.finishLoading(with: Self.invalidRangeError())
                return
            }
            loadingRequest.finishLoading()
        }
        store(task, for: requestID)
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        removeTask(for: ObjectIdentifier(loadingRequest))?.cancel()
    }

    deinit {
        session.invalidateAndCancel()
    }

    private func store(_ task: URLSessionDataTask, for requestID: ObjectIdentifier) {
        taskLock.lock()
        let previous = tasks.updateValue(task, forKey: requestID)
        taskLock.unlock()
        previous?.cancel()
    }

    @discardableResult
    private func removeTask(for requestID: ObjectIdentifier) -> URLSessionDataTask? {
        taskLock.lock()
        let task = tasks.removeValue(forKey: requestID)
        taskLock.unlock()
        return task
    }

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
        let upperBound: Int
        if let requestedLength {
            upperBound = min(lowerBound + requestedLength, data.count)
        } else {
            upperBound = data.count
        }
        guard upperBound > lowerBound else { return nil }
        return data.subdata(in: lowerBound..<upperBound)
    }

    private static func httpError(status: Int) -> NSError {
        NSError(
            domain: "tech.digia.video.http",
            code: status,
            userInfo: [NSLocalizedDescriptionKey: "Video request failed with HTTP status \(status)."]
        )
    }

    private static func invalidRangeError() -> NSError {
        NSError(
            domain: "tech.digia.video.range",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Video server returned an invalid byte-range response."]
        )
    }
}

struct DigiaVideoPlaybackBundle {
    let player: AVPlayer
    let looper: AVPlayerLooper?

    static func make(url: URL, looping: Bool) async throws -> DigiaVideoPlaybackBundle {
        let playbackURL = try await DigiaVideoFileCache.shared.localURL(for: url)
        return make(asset: DigiaVideoStreaming.makeAsset(for: playbackURL), looping: looping)
    }

    static func make(asset: AVURLAsset, looping: Bool) -> DigiaVideoPlaybackBundle {
        let item = AVPlayerItem(asset: asset)
        if looping {
            let queuePlayer = AVQueuePlayer(playerItem: item)
            let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            return DigiaVideoPlaybackBundle(player: queuePlayer, looper: looper)
        }
        return DigiaVideoPlaybackBundle(player: AVPlayer(playerItem: item), looper: nil)
    }

    func releasePlaybackResources() {
        looper?.disableLooping()
        player.pause()
        if let queuePlayer = player as? AVQueuePlayer {
            queuePlayer.removeAllItems()
        } else {
            player.replaceCurrentItem(with: nil)
        }
    }
}
