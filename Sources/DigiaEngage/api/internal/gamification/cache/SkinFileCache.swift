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
    /// One self-contained skin may hold this many bytes. The old whole-bundle
    /// budget (3 MB + 10%), now spent on the single file.
    nonisolated static let singleFileMaxBytes = 3 * 1024 * 1024 + (3 * 1024 * 1024) / 10
    /// The whole skin cache holds this many bytes across entries.
    nonisolated static let totalMaxBytes: Int64 = 16 * 1024 * 1024

    private nonisolated static let rootDirectoryName = "digia-engage-skins"

    private let cachesDirectory: URL?
    private let networkClient: any NetworkClient

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
    /// `Caches` or the folder holds anything but the one file. A hit
    /// refreshes the entry's recency for eviction.
    func cachedFile(skinId: String, version: Int) -> URL? {
        guard let file = fileURL(skinId: skinId, version: version),
              FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        Self.touch(file)
        return file
    }

    /// Stores one downloaded entry: temp file plus an atomic rename, then
    /// evicts the least-recently-used entries until the total fits. Throws on
    /// an empty or over-budget body, or when there is no caches directory.
    @discardableResult
    func store(skinId: String, version: Int, data: Data) throws -> URL {
        guard let file = fileURL(skinId: skinId, version: version) else {
            throw SkinFileCacheError.noCachesDirectory
        }
        guard !data.isEmpty, data.count <= Self.singleFileMaxBytes else {
            throw SkinFileCacheError.invalidFile
        }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        try data.write(to: temp, options: .atomic)
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
        evictOldEntries()
        return file
    }

    // MARK: - Fetch

    /// Downloads `bundleUrl` (the skin's single self-contained `index.html`)
    /// and stores it under `skinId`/`version`. Throws on an unusable URL, a
    /// transport failure, a non-2xx status, or an empty or over-budget body.
    /// Already-cached entries are not re-downloaded.
    func download(bundleUrl: String, skinId: String, version: Int) async throws -> URL {
        if let cached = cachedFile(skinId: skinId, version: version) { return cached }
        guard let url = URL(string: bundleUrl),
              url.scheme == "http" || url.scheme == "https"
        else { throw SkinFileCacheError.badURL }
        let response = try await networkClient.execute(request: NetworkRequest(
            url: url, method: .get, connectTimeout: 30, readTimeout: 30))
        guard response.isSuccessful else {
            throw SkinFileCacheError.badResponse
        }
        guard let data = response.body, !data.isEmpty,
              data.count <= Self.singleFileMaxBytes
        else {
            throw SkinFileCacheError.invalidFile
        }
        return try store(skinId: skinId, version: version, data: data)
    }

    /// Prefetches skins fire-and-forget: already-cached entries are skipped,
    /// failures are logged and dropped, and the next trigger retries.
    func prefetch(_ skins: [(bundleUrl: String, skinId: String, version: Int)]) async {
        for skin in skins {
            if cachedFile(skinId: skin.skinId, version: skin.version) != nil { continue }
            do {
                _ = try await download(
                    bundleUrl: skin.bundleUrl, skinId: skin.skinId, version: skin.version)
            } catch {
                log.w(
                    "Skin prefetch failed (skinId=\(skin.skinId), version=\(skin.version))",
                    error: "\(error)")
            }
        }
    }

    // MARK: - Eviction

    /// Evicts the least-recently-modified entries until the total fits the
    /// cap. Only entry files count and go; a version directory left empty is
    /// pruned, and anything mid-write (a `.partial` temp) is never touched.
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

    private func rootDirectory() -> URL? {
        cachesDirectory?.appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
    }
}

enum SkinFileCacheError: Error {
    case noCachesDirectory
    case badURL
    case badResponse
    case invalidFile
}
