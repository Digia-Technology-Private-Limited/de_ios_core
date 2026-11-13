import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// What a `SkinPrefetcher.prefetch` call did.
enum SkinPrefetchResult: Sendable, Equatable {
    /// The bundle was already complete in the cache; nothing was downloaded.
    case alreadyCached
    /// The bundle downloaded, verified, and moved into the cache.
    case downloaded
    /// The bundle was not fetched, and retrying later is only useful for
    /// `cacheFull` (a bigger cap) — never for a malformed bundle.
    case skipped(SkinPrefetchSkip)
    /// The network or the disk failed mid-prefetch. The partial download is
    /// dropped; the next trigger retries from scratch.
    case failed
}

/// Why a prefetch was skipped without touching the network for files.
enum SkinPrefetchSkip: Sendable, Equatable {
    /// The `bundleUrl` string is not a usable http(s) URL.
    case badURL
    /// `files.json` is missing, undecodable, empty, or lists an unsafe path.
    case invalidManifest
    /// A file is over 1 MB.
    case fileTooLarge
    /// The manifest total is over 3 MB plus a 10% margin.
    case overBudget
    /// No room under the cap, even after evicting everything evictable.
    case cacheFull
}

/// Downloads skin bundles into a ``SkinBundleCache``.
///
/// Triggers (ERD 1): a gamification campaign payload arrives, or
/// `grantChance` returns granted — the intake calls
/// `prefetch(bundleUrl:)` with the payload's `bundleUrl` and drops the
/// result. As an actor, concurrent triggers serialize: one download at a
/// time, and a failed download is dropped and retried at the next trigger.
actor SkinPrefetcher {

    /// One file may be at most 1 MB (skin bundle size budget).
    static let perFileMaxBytes = 1 * 1024 * 1024

    /// A bundle may total at most 3 MB plus a 10% margin (contract open
    /// question Q1 reads the ERD's "small margin" as this number).
    static let totalMaxBytes = 3 * 1024 * 1024 + (3 * 1024 * 1024) / 10

    private let cache: SkinBundleCache
    private let session: URLSession

    init(cache: SkinBundleCache, session: URLSession = .shared) {
        self.cache = cache
        self.session = session
    }

    /// Prefetches the bundle for a payload `bundleUrl` string.
    func prefetch(bundleUrl: String) async -> SkinPrefetchResult {
        guard let url = URL(string: bundleUrl),
              url.scheme == "http" || url.scheme == "https"
        else {
            log.w("Skin prefetch skipped: unusable bundleUrl")
            return .skipped(.badURL)
        }
        return await prefetch(bundleUrl: url)
    }

    /// Prefetches the bundle at `bundleUrl` (normally the bundle's
    /// `index.html`): reads `files.json` next to it, checks total and
    /// per-file sizes, downloads every file into a temp folder, checks each
    /// size, and moves the folder into the cache.
    func prefetch(bundleUrl: URL) async -> SkinPrefetchResult {
        if await cache.isComplete(bundleUrl: bundleUrl) {
            return .alreadyCached
        }
        let folder = SkinBundleCache.bundleFolderURL(for: bundleUrl)
        let manifestURL = folder.appendingPathComponent("files.json")

        let manifestData: Data
        do {
            manifestData = try await get(manifestURL)
        } catch {
            log.w("Skin prefetch failed: files.json unreachable", extras: ["url": manifestURL.absoluteString])
            return .failed
        }
        guard let manifest = try? JSONDecoder().decode(SkinBundleManifest.self, from: manifestData),
              !manifest.files.isEmpty,
              manifest.files.allSatisfy({ isSafeRelativePath($0.path) && $0.size >= 0 })
        else {
            log.w("Skin prefetch skipped: invalid manifest")
            return .skipped(.invalidManifest)
        }
        if manifest.files.contains(where: { $0.size > Self.perFileMaxBytes }) {
            log.w("Skin prefetch skipped: file over 1 MB")
            return .skipped(.fileTooLarge)
        }
        let total = manifest.files.reduce(0) { $0 + $1.size }
        if total > Self.totalMaxBytes {
            log.w("Skin prefetch skipped: bundle over budget")
            return .skipped(.overBudget)
        }
        guard await cache.evictIfNeeded(
            freeingFor: total, excluding: SkinBundleCache.cacheKey(forBundleFolder: folder))
        else {
            log.w("Skin prefetch skipped: cache full")
            return .skipped(.cacheFull)
        }

        let staged: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("digia-skin-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            for entry in manifest.files {
                let fileURL = folder.appendingPathComponent(entry.path)
                let data = try await get(fileURL)
                guard data.count == entry.size else {
                    throw SkinPrefetchError.sizeMismatch(path: entry.path)
                }
                let destination = staged.appendingPathComponent(entry.path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
            try await cache.install(bundleUrl: bundleUrl, manifest: manifest, stagedDirectory: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            log.w("Skin prefetch failed: download dropped", extras: ["error": String(describing: error)])
            return .failed
        }
        return .downloaded
    }

    // MARK: - Private

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SkinPrefetchError.badResponse(url: url.absoluteString)
        }
        return data
    }

    /// A manifest path is safe when it stays inside the bundle folder: a
    /// relative path with no `..` segment and no absolute form.
    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.split(separator: "/").contains("..")
    }
}

enum SkinPrefetchError: Error {
    case badResponse(url: String)
    case sizeMismatch(path: String)
}
