// Derived from VIMediaCache (MIT), Copyright (c) 2016 Vito Zhang <vvitozhang@gmail.com>.
//
// The MIT License (MIT)
// Copyright (c) 2016 Vito Zhang <vvitozhang@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import CryptoKit
import Foundation

/// Stable cache identity for a URL: the hex SHA-256 of its absolute string.
internal func mediaCacheKey(for url: URL) -> String {
    SHA256.hash(data: Data(url.absoluteString.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    var collected: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class StoreRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [String: MediaRangeCacheStore] = [:]

    func store(folder: URL, maxBytes: Int64) -> MediaRangeCacheStore {
        let key = folder.standardizedFileURL.path + "#" + String(maxBytes)
        lock.lock()
        defer { lock.unlock() }
        if let existing = stores[key] {
            return existing
        }
        let created = MediaRangeCacheStore(folder: folder, maxBytes: maxBytes)
        stores[key] = created
        return created
    }
}

/// Process-wide range cache: one store per folder. The player reads through
/// this store; stored ranges are served from disk and missing ranges are
/// fetched with HTTP Range and written as they arrive, so one download serves
/// both playback and caching. Partial files are valid entries. Servers without
/// Range support fall back to a whole-file save.
///
/// All state lives on this actor, so every file access runs off the main
/// thread and concurrent readers of one URL share a single fetch per range.
internal actor MediaRangeCacheStore {
    internal static let defaultMaxBytes: Int64 = 256 * 1_024 * 1_024

    private static let registry = StoreRegistry()

    /// The process-wide store for `folder` (created on first use). Direct
    /// `init` is for tests; production always goes through here so a second
    /// store can never be opened on the same folder.
    internal static func shared(
        folder: URL? = nil,
        maxBytes: Int64 = MediaRangeCacheStore.defaultMaxBytes
    ) -> MediaRangeCacheStore {
        let resolved = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tech.digia.engage.media", isDirectory: true)
        return registry.store(folder: resolved, maxBytes: maxBytes)
    }

    private let folder: URL
    private let maxBytes: Int64
    private let client: any RangeFetchClient
    private var files: [String: CachedMediaFile] = [:]
    private var inFlight: [String: Task<Void, Error>] = [:]
    private var active: Set<String> = []

    internal init(folder: URL, maxBytes: Int64 = MediaRangeCacheStore.defaultMaxBytes, client: (any RangeFetchClient)? = nil) {
        self.folder = folder
        self.maxBytes = max(maxBytes, 1)
        self.client = client ?? URLSessionRangeFetchClient()
    }

    /// Stored playback metadata without creating any files. Used to fill the
    /// content-information request before the first byte is read.
    internal func contentInfo(for url: URL) -> MediaContentInfo? {
        let key = mediaCacheKey(for: url)
        if let entry = files[key] {
            return entry.index.contentInfo
        }
        let dataURL = folder.appendingPathComponent(Self.fileName(for: url, key: key))
        guard FileManager.default.fileExists(atPath: dataURL.path) else { return nil }
        return RangeIndexPersistence.load(dataURL: dataURL)?.contentInfo
    }

    /// Reads `length` bytes from `offset` (nil = to end of resource).
    internal func read(url: URL, offset: Int64, length: Int?) async throws -> Data {
        let collector = DataCollector()
        try await serve(url: url, offset: offset, length: length, onResponse: { _ in }, onData: { collector.append($0) })
        return collector.collected
    }

    /// Warms a range into the cache, discarding the bytes.
    internal func warm(url: URL, offset: Int64, length: Int?) async throws {
        try await serve(url: url, offset: offset, length: length, onResponse: { _ in }, onData: { _ in })
    }

    /// Serves a range progressively: stored bytes are emitted from disk and
    /// missing bytes are fetched and written as they arrive. `onData` receives
    /// exactly the requested window, in order. Cancelling the caller's task
    /// cancels a fetch this call started; co-waiters sharing that fetch also
    /// observe cancellation.
    internal func serve(
        url: URL,
        offset: Int64,
        length: Int?,
        onResponse: @escaping @Sendable (MediaContentInfo) -> Void,
        onData: @escaping @Sendable (Data) -> Void
    ) async throws {
        try Task.checkCancellation()
        let key = mediaCacheKey(for: url)
        let entry = try resolveEntry(url: url, key: key)
        active.insert(key)
        defer { active.remove(key) }
        touch(entry)

        let start = max(0, offset)
        if let info = entry.index.contentInfo {
            onResponse(info)
        }
        if length == nil, !entry.index.contentInfo.hasKnownLengthOrMissing {
            // Total unknown: emit the stored run from `start`, then fetch the
            // tail open-ended. (A stored info with unknown length counts as
            // "unknown" here; the fetch upgrades it when the total arrives.)
            let prefixEnd = entry.index.contiguousEnd(from: start)
            if prefixEnd > start, let prefix = entry.read(offset: start, length: prefixEnd - start), !prefix.isEmpty {
                onData(prefix)
            }
            _ = try await fetchRemote(url: url, key: key, offset: max(start, prefixEnd), length: nil, onResponse: onResponse, onData: onData)
            entry.persist()
            evictIfNeeded()
            return
        }

        var remaining: Int64
        if let length {
            guard length > 0 else { return }
            remaining = Int64(length)
        } else {
            let total = entry.index.contentInfo?.contentLength ?? MediaContentInfo.unknownLength
            guard total >= 0 else { return }
            remaining = max(Int64(0), total - start)
            guard remaining > 0 else { return }
        }
        if let total = entry.index.contentInfo?.contentLength, total >= 0 {
            remaining = min(remaining, max(Int64(0), total - start))
            guard remaining > 0 else { return }
        }

        var cursor = start
        serveLoop: while remaining > 0 {
            try Task.checkCancellation()
            let actions = planCacheActions(
                requestedOffset: cursor,
                requestedLength: remaining,
                fragments: entry.index.storedRanges
            )
            guard let first = actions.first else { break }
            switch first.kind {
            case .local:
                let wanted = first.length ?? remaining
                guard let data = entry.read(offset: first.offset, length: wanted), !data.isEmpty else {
                    entry.removeFragments(overlapping: first.offset ..< first.offset + wanted)
                    continue
                }
                onData(data)
                let advanced = Int64(data.count)
                cursor += advanced
                remaining -= advanced
                if advanced < wanted {
                    entry.removeFragments(overlapping: first.offset + advanced ..< first.offset + wanted)
                }
            case .remote:
                let fetched = try await fetchRemote(
                    url: url,
                    key: key,
                    offset: first.offset,
                    length: first.length,
                    onResponse: onResponse,
                    onData: onData
                )
                if fetched == 0 {
                    break serveLoop
                }
                cursor += fetched
                remaining -= fetched
            }
        }
        entry.persist()
        evictIfNeeded()
    }

    // MARK: - Private

    private static func fileName(for url: URL, key: String) -> String {
        let candidate = url.pathExtension
        let isSafe = !candidate.isEmpty
            && candidate.count <= 8
            && candidate.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        return "\(key).\(isSafe ? candidate : "media")"
    }

    private func resolveEntry(url: URL, key: String) throws -> CachedMediaFile {
        if let entry = files[key] {
            return entry
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = CachedMediaFile(dataURL: folder.appendingPathComponent(Self.fileName(for: url, key: key)))
        files[key] = entry
        return entry
    }

    private func touch(_ entry: CachedMediaFile) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.dataURL.path)
    }

    /// Fetches one missing range. Concurrent readers of the same range share a
    /// single fetch; if the reader that started it is cancelled, the shared
    /// fetch is cancelled and co-waiters observe cancellation. Returns the
    /// number of requested-window bytes emitted via `onData`.
    private func fetchRemote(
        url: URL,
        key: String,
        offset: Int64,
        length: Int64?,
        onResponse: @escaping @Sendable (MediaContentInfo) -> Void,
        onData: @escaping @Sendable (Data) -> Void
    ) async throws -> Int64 {
        let dedupKey = key + "#" + String(offset) + "-" + (length.map(String.init) ?? "end")
        if let existing = inFlight[dedupKey] {
            try await existing.value
            try Task.checkCancellation()
            guard let entry = files[key] else { return 0 }
            if let length {
                guard let data = entry.read(offset: offset, length: length), !data.isEmpty else { return 0 }
                onData(data)
                return Int64(data.count)
            }
            guard let data = entry.readToEnd(from: offset), !data.isEmpty else { return 0 }
            onData(data)
            return Int64(data.count)
        }
        let fetchTask = Task<Void, Error> {
            try await self.fetchAndStore(url: url, key: key, offset: offset, length: length, onResponse: onResponse, onData: onData)
        }
        inFlight[dedupKey] = fetchTask
        do {
            try await withTaskCancellationHandler(
                operation: { try await fetchTask.value },
                onCancel: { fetchTask.cancel() }
            )
        } catch {
            inFlight[dedupKey] = nil
            throw error
        }
        inFlight[dedupKey] = nil
        guard let entry = files[key] else { return 0 }
        if let length {
            guard let data = entry.read(offset: offset, length: length), !data.isEmpty else { return 0 }
            return Int64(data.count)
        }
        guard let data = entry.readToEnd(from: offset), !data.isEmpty else { return 0 }
        return Int64(data.count)
    }

    /// Performs the fetch: records metadata, writes bytes as they arrive (never
    /// exceeding the per-entry cap), and emits exactly the requested window.
    /// A server that ignores Range answers 200 with the whole body, which is
    /// saved as one complete file. Local I/O failures degrade to pass-through
    /// serving instead of failing playback.
    private func fetchAndStore(
        url: URL,
        key: String,
        offset: Int64,
        length: Int64?,
        onResponse: @escaping @Sendable (MediaContentInfo) -> Void,
        onData: @escaping @Sendable (Data) -> Void
    ) async throws {
        guard let entry = files[key] else { throw URLError(.unknown) }
        let headerRange: Range<Int64>? = length.map { offset ..< offset + $0 } ?? offset ..< Int64.max
        let result = try await client.fetch(url: url, range: headerRange)
        if let total = result.totalLength, total >= 0 {
            entry.updateContentInfo(MediaContentInfo(
                contentType: mediaCacheUTI(forMimeType: result.contentType),
                contentLength: total,
                byteRangeAccessSupported: result.rangeSupported
            ))
            onResponse(entry.index.contentInfo ?? MediaContentInfo(
                contentType: mediaCacheUTI(forMimeType: result.contentType),
                contentLength: total,
                byteRangeAccessSupported: result.rangeSupported
            ))
        } else if entry.index.contentInfo == nil {
            let info = MediaContentInfo(
                contentType: mediaCacheUTI(forMimeType: result.contentType),
                byteRangeAccessSupported: result.rangeSupported
            )
            entry.updateContentInfo(info)
            onResponse(info)
        }

        let windowEnd: Int64? = length.map { offset + $0 }
        var cursor = result.rangeSupported ? offset : 0
        var writable = entry.maxStoredEnd <= maxBytes
        do {
            for try await chunk in result.chunks {
                try Task.checkCancellation()
                guard !chunk.isEmpty else { continue }
                let chunkStart = cursor
                cursor += Int64(chunk.count)
                if writable {
                    if entry.maxStoredEnd + Int64(chunk.count) <= maxBytes {
                        try entry.write(chunk, at: chunkStart)
                    } else {
                        writable = false
                    }
                }
                let sliceStart = max(chunkStart, offset)
                let sliceEnd = windowEnd.map { min(cursor, $0) } ?? cursor
                if sliceEnd > sliceStart {
                    let from = Int(sliceStart - chunkStart)
                    let to = Int(sliceEnd - chunkStart)
                    let slice = chunk.subdata(in: from ..< to)
                    onData(slice)
                }
                if let windowEnd, cursor >= windowEnd {
                    break
                }
            }
        } catch {
            entry.persist()
            throw error
        }
        entry.persist()
    }

    private func evictIfNeeded() {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var entries: [(URL, Int64, Date)] = []
        var totalBytes: Int64 = 0
        for url in urls {
            let name = url.lastPathComponent
            guard !name.hasSuffix(".idx") && !name.hasSuffix(".tmp") else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                values.isRegularFile == true
            else {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard totalBytes > maxBytes else { return }
        entries.sort { $0.2 < $1.2 }
        let keyByName: [String: String] = Dictionary(
            uniqueKeysWithValues: files.map { (entryFileName(forKey: $0.key) ?? "", $0.key) }
        )
        for (url, size, _) in entries where totalBytes > maxBytes {
            let entryKey = keyByName[url.lastPathComponent]
            if let entryKey, active.contains(entryKey) {
                continue
            }
            if let entryKey, let entry = files[entryKey] {
                entry.close()
                files[entryKey] = nil
            }
            guard (try? fileManager.removeItem(at: url)) != nil else { continue }
            try? fileManager.removeItem(at: RangeIndexPersistence.indexURL(forDataURL: url))
            totalBytes -= size
        }
    }

    private func entryFileName(forKey key: String) -> String? {
        files[key].map { $0.dataURL.lastPathComponent }
    }
}

private extension Optional where Wrapped == MediaContentInfo {
    var hasKnownLengthOrMissing: Bool {
        switch self {
        case .none:
            return false
        case .some(let info):
            return info.hasKnownLength
        }
    }
}
