import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Caches one self-contained skin `index.html` per skin version.
///
/// Layout: `<Caches>/digia-engage-skins/<safeSkinId>/<version>/index.html`.
/// Entries are immutable — a new skin version is a new directory, so a cached
/// file is never revalidated. The cache holds at most 16 MB: a hit refreshes
/// recency, and every write evicts the least-recently-used entries until the
/// total fits. Downloads go through the SDK's network client, never a
/// bare `URLSession`. Prefetched on campaign sync, downloaded-then-shown on a
/// cache miss at show time; a download failure skips the show, never crashes it.
struct SkinFileCache: Sendable {
    /// The cached entry file name.
    nonisolated static let fileName = "index.html"
    /// The in-progress write name. Non-hidden, so a crash-orphaned temp is
    /// visible to the stray sweep in `store` — Android names it the same way.
    nonisolated static let tempFileName = "index.html.tmp"
    /// One self-contained skin may hold this many bytes. The old whole-bundle
    /// budget (3 MB + 10%), now spent on the single file.
    nonisolated static let singleFileMaxBytes = 3 * 1024 * 1024 + (3 * 1024 * 1024) / 10
    /// The whole skin cache holds this many bytes across entries.
    nonisolated static let totalMaxBytes: Int64 = 16 * 1024 * 1024

    private nonisolated static let rootDirectoryName = "digia-engage-skins"

    private let cachesDirectory: URL?
    private let networkClient: any NetworkClient
    /// The serial guard around every file read, write, touch and eviction —
    /// Android's `synchronized(lock)` in `SkinFileCache`. One box per cache, so
    /// copies of the same cache still exclude each other. Callers hop off the
    /// main actor for the heavy work (see `download`); the lock keeps
    /// concurrent misses from interleaving a store with an eviction.
    private let lock = CacheLock()

    /// - Parameters:
    ///   - cachesDirectory: The app's `Caches` directory. Tests pass a
    ///     temporary directory, so they never touch the real one.
    ///   - networkClient: The SDK's network client, carrying its auth.
    init(
        cachesDirectory: URL? = SkinFileCache.defaultCachesDirectory,
        networkClient: any NetworkClient
    ) {
        self.cachesDirectory = cachesDirectory
        self.networkClient = networkClient
    }

    /// The app's caches directory, where the skins live. Tests pass a
    /// temporary directory instead, so they never touch the real one.
    nonisolated static var defaultCachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    // MARK: - Identity

    /// The cache directory for a skin version. The skin id is sanitized to a
    /// safe path segment; the version keeps immutable entries apart.
    nonisolated static func directoryName(skinId: String, version: Int) -> String {
        "\(safeSkinId(skinId))/\(version)"
    }

    /// Replaces every unsafe path character with `_`, so any backend skin id
    /// maps to one safe directory segment. Pure, so tests pin it.
    nonisolated static func safeSkinId(_ skinId: String) -> String {
        let safe = skinId.unicodeScalars.map { scalar in
            ((scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == "_"
                || scalar == ".") ? Character(scalar) : "_"
        }
        let result = String(safe)
        return result.isEmpty ? "_" : result
    }

    // MARK: - Lookup and install

    /// The cache location for a skin version, whether present or not.
    func fileURL(skinId: String, version: Int) -> URL? {
        rootDirectory()?.appendingPathComponent(Self.directoryName(skinId: skinId, version: version))
            .appendingPathComponent(Self.fileName)
    }

    /// The cached entry, or nil on a miss — including when the OS cleared
    /// `Caches`, when the folder holds anything but the one file, or when the
    /// file on disk is empty or over the per-file cap (Android's `lookup`
    /// misses there too, instead of serving it). A hit refreshes the entry's
    /// recency for eviction.
    func cachedFile(skinId: String, version: Int) -> URL? {
        lock.withLock {
            guard let file = fileURL(skinId: skinId, version: version),
                  isCompleteFile(at: file)
            else { return nil }
            Self.touch(file)
            return file
        }
    }

    /// A servable entry: a real file, non-empty, and within the per-file cap.
    private func isCompleteFile(at file: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        else { return false }
        let bytes = size.int64Value
        return bytes > 0 && bytes <= Self.singleFileMaxBytes
    }

    /// The fixed `Content-Security-Policy` applied to every cached skin.
    /// Character-identical to Android's `SKIN_CSP_HEADER`. iOS loads a local
    /// file, which cannot carry a header, so the stored copy gains a meta tag.
    nonisolated static let cspHeader =
        "default-src 'none'; " +
        "script-src 'self' 'unsafe-inline'; " +
        "style-src 'self' 'unsafe-inline'; " +
        "font-src 'self' data:; " +
        "media-src 'self' data:; " +
        "connect-src 'self'; " +
        "img-src 'self' https: data:"

    /// Stores one downloaded entry: temp file plus an atomic rename, then
    /// evicts the least-recently-used entries until the total fits. Throws on
    /// an empty or over-budget body, or when there is no caches directory.
    /// Serialized against every other read, write and eviction.
    @discardableResult
    func store(skinId: String, version: Int, data: Data) throws -> URL {
        guard let file = fileURL(skinId: skinId, version: version) else {
            throw SkinFileCacheError.noCachesDirectory
        }
        guard !data.isEmpty, data.count <= Self.singleFileMaxBytes else {
            throw SkinFileCacheError.invalidFile
        }
        return try lock.withLock {
            let stored = Self.withCspMetaTag(data)
            guard stored.count <= Self.singleFileMaxBytes else {
                throw SkinFileCacheError.invalidFile
            }
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let temp = directory.appendingPathComponent(Self.tempFileName)
            try stored.write(to: temp, options: .atomic)
            do {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                try FileManager.default.moveItem(at: temp, to: file)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
            Self.touch(file)
            deleteStrayTempFiles()
            evictOldEntries()
            return file
        }
    }

    // MARK: - Fetch

    /// Every working skin defines `window.DigiaBridge`; see `download`.
    static let bridgeMarker = Data("DigiaBridge".utf8)

    /// Downloads `bundleUrl` (the skin's single self-contained `index.html`)
    /// and stores it under `skinId`/`version`. Throws on an unusable URL (not
    /// https, nor http from the API base origin — see `GameUrlPolicy.allowsBundle`), a
    /// transport failure, a non-2xx status, an empty or over-budget body, or a
    /// body without `DigiaBridge` (a captive portal or proxy page served as 200:
    /// native replies only through `window.DigiaBridge`, so such a file can
    /// never run, and caching it would pin the broken game until the version
    /// changes). Already-cached entries are not re-downloaded. The read is
    /// capped: the body never grows past the per-file cap (`executeCapped`
    /// aborts the stream there, like Android's mid-stream abort), and anything
    /// past it is `invalidFile`.
    func download(bundleUrl: String, skinId: String, version: Int) async throws -> URL {
        if let cached = cachedFile(skinId: skinId, version: version) { return cached }
        guard let url = URL(string: bundleUrl), GameUrlPolicy.allowsBundle(url)
        else { throw SkinFileCacheError.badURL }
        let response = try await networkClient.executeCapped(
            request: NetworkRequest(
                url: url, method: .get, connectTimeout: 30, readTimeout: 30),
            maxBytes: Self.singleFileMaxBytes)
        guard response.isSuccessful else {
            throw SkinFileCacheError.badResponse
        }
        guard let data = response.body, !data.isEmpty,
              data.count <= Self.singleFileMaxBytes,
              data.range(of: Self.bridgeMarker) != nil
        else {
            throw SkinFileCacheError.invalidFile
        }
        // The write plus the eviction enumeration run on a background thread
        // instead of the caller's actor (usually main); the lock keeps
        // concurrent misses from interleaving. A file-system failure there is
        // `storeFailed`, so a prefetch reports it as `store_failed`, like Android.
        do {
            return try await Task.detached {
                try self.store(skinId: skinId, version: version, data: data)
            }.value
        } catch let error as SkinFileCacheError {
            throw error
        } catch {
            throw SkinFileCacheError.storeFailed(error)
        }
    }

    /// Prefetches skins fire-and-forget: already-cached entries are skipped,
    /// failures are logged, reported to `onDropped` with a reason, and dropped,
    /// and the next trigger retries. An unusable `bundleUrl` is skipped silently,
    /// like Android. Cooperative with cancellation: a torn-down SDK stops
    /// between skins and reports nothing.
    func prefetch(
        _ skins: [(bundleUrl: String, skinId: String, version: Int)],
        onDropped: @Sendable (_ skinId: String, _ version: Int, _ reason: String) -> Void = { _, _, _ in }
    ) async {
        for skin in skins {
            if Task.isCancelled { return }
            if cachedFile(skinId: skin.skinId, version: skin.version) != nil { continue }
            do {
                _ = try await download(
                    bundleUrl: skin.bundleUrl, skinId: skin.skinId, version: skin.version)
            } catch {
                log.w(
                    "Skin prefetch failed (skinId=\(skin.skinId), version=\(skin.version))",
                    error: "\(error)")
                if Task.isCancelled { return }
                if let reason = Self.prefetchDropReason(error) {
                    onDropped(skin.skinId, skin.version, reason)
                }
            }
        }
    }

    /// The analytics reason for a dropped prefetch, matching Android's
    /// `SkinPrefetcher`; nil for an unusable URL, which Android also skips.
    private static func prefetchDropReason(_ error: Error) -> String? {
        switch error as? SkinFileCacheError {
        case .badURL: return nil
        case .invalidFile: return "invalid_file"
        case .noCachesDirectory, .storeFailed: return "store_failed"
        case .badResponse, nil: return "download_failed"
        }
    }

    // MARK: - Eviction

    /// Deletes crash-orphaned temps: a crash between the write and the rename
    /// leaves one behind, and temps are non-hidden so this sweep sees them —
    /// like Android's `deleteStrayTempFiles`. Call with the lock held.
    private func deleteStrayTempFiles() {
        guard let root = rootDirectory() else { return }
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return }
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(".tmp"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Evicts the least-recently-modified entries until the total fits the
    /// cap. Only entry files count and go; a version directory left empty is
    /// pruned, and anything mid-write (a `.tmp` temp) is never touched. Call
    /// with the lock held.
    private func evictOldEntries() {
        guard let root = rootDirectory() else { return }
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])
        else { return }
        var files: [(url: URL, size: Int64, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == Self.fileName,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        files.sort { $0.modified < $1.modified }
        for file in files where total > Self.totalMaxBytes {
            guard (try? fileManager.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            var directory = file.url.deletingLastPathComponent()
            for _ in 0..<2 {
                guard (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true
                else { break }
                try? fileManager.removeItem(at: directory)
                directory = directory.deletingLastPathComponent()
            }
        }
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    /// Returns `data` with the CSP meta tag inserted. The tag goes first in
    /// `<head>`; without a `<head>` it goes after the doctype or `<html>` tag.
    /// Non-HTML bytes pass through unchanged, so a bad bundle never fails here.
    nonisolated static func withCspMetaTag(_ data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) else { return data }
        let tag =
            "<meta http-equiv=\"Content-Security-Policy\" content=\"\(cspHeader)\">"
        if let headRange = html.range(
            of: "<head[^>]*>", options: [.caseInsensitive, .regularExpression])
        {
            html.insert(contentsOf: tag, at: headRange.upperBound)
            return Data(html.utf8)
        }
        if let htmlRange = html.range(
            of: "<html[^>]*>", options: [.caseInsensitive, .regularExpression])
        {
            html.insert(contentsOf: tag, at: htmlRange.upperBound)
            return Data(html.utf8)
        }
        return data
    }

    private func rootDirectory() -> URL? {
        cachesDirectory?.appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
    }
}

enum SkinFileCacheError: Error {
    case noCachesDirectory
    case badURL
    case badResponse
    case invalidFile
    /// Writing the downloaded file to the cache failed.
    case storeFailed(Error)
}

/// The serial guard around every skin-cache file read, write, touch and
/// eviction. A box, because the lock must be shared by every copy of the
/// cache struct — copying the struct must not fork the exclusion.
private final class CacheLock: @unchecked Sendable {
    private let ns = NSLock()

    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        ns.lock()
        defer { ns.unlock() }
        return try work()
    }
}
