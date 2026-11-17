import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Caches one self-contained skin `index.html` per skin version.
///
/// Layout: `<Caches>/digia-engage-skins/<skinId>/<version>/index.html`.
/// Entries are immutable — a new skin version is a new directory, so a cached
/// file is never revalidated and never evicted (one file per skin version is
/// small; the OS may clear `Caches` under pressure, which just reads as a
/// miss). Prefetched on campaign sync, downloaded-then-shown on a cache miss
/// at show time; a download failure skips the show, never crashes it.
struct SkinFileCache: Sendable {
    /// The cached entry file name.
    nonisolated static let fileName = "index.html"
    /// One self-contained skin may hold this many bytes. The old whole-bundle
    /// budget (3 MB + 10%), now spent on the single file.
    nonisolated static let singleFileMaxBytes = 3 * 1024 * 1024 + (3 * 1024 * 1024) / 10

    private nonisolated static let rootDirectoryName = "digia-engage-skins"

    private let cachesDirectory: URL?
    private let session: URLSession

    /// - Parameters:
    ///   - cachesDirectory: The app's `Caches` directory. Tests pass a
    ///     temporary directory, so they never touch the real one.
    init(
        cachesDirectory: URL? = SkinFileCache.defaultCachesDirectory,
        session: URLSession = .shared
    ) {
        self.cachesDirectory = cachesDirectory
        self.session = session
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
    /// `Caches` or the folder holds anything but the one file.
    func cachedFile(skinId: String, version: Int) -> URL? {
        guard let file = fileURL(skinId: skinId, version: version),
              FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        return file
    }

    /// Stores one downloaded entry atomically.
    @discardableResult
    func store(skinId: String, version: Int, data: Data) throws -> URL {
        guard let file = fileURL(skinId: skinId, version: version) else {
            throw SkinFileCacheError.noCachesDirectory
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }

    // MARK: - Fetch

    /// Downloads `bundleUrl` (the skin's single self-contained `index.html`)
    /// and stores it under `skinId`/`version`. Throws on an unusable URL, a
    /// transport failure, a non-200 status, an empty body, or an over-budget
    /// file. Already-cached entries are not re-downloaded.
    func download(bundleUrl: String, skinId: String, version: Int) async throws -> URL {
        if let cached = cachedFile(skinId: skinId, version: version) { return cached }
        guard let url = URL(string: bundleUrl),
              url.scheme == "http" || url.scheme == "https"
        else { throw SkinFileCacheError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SkinFileCacheError.badResponse
        }
        guard !data.isEmpty, data.count <= Self.singleFileMaxBytes else {
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
