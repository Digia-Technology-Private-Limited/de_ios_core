import CryptoKit
import Foundation
import WebKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// The `files.json` manifest of a skin bundle: every file the SDK must cache,
/// except `files.json` and `preview.png` themselves.
struct SkinBundleManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        /// Path relative to the bundle folder, e.g. `js/app.js`.
        let path: String
        /// Exact byte size the downloaded file must have.
        let size: Int
    }

    let files: [Entry]
}

/// The on-disk record marking a bundle complete: the folder it was fetched
/// from, the manifest it was verified against, and when it was last used for
/// LRU eviction.
private struct SkinBundleRecord: Codable {
    var key: String
    var folderURL: String
    var files: [SkinBundleManifest.Entry]
    var lastUsed: Date
}

enum SkinCacheError: Error {
    case noCachesDirectory
}

/// Tracks the in-flight CDN-fallback tasks of ``SkinBundleCache``. Plain
/// `Sendable` so the URLSession completion handler can own it without
/// hopping to the main actor; exactly-once delivery is by `take`/`cancel`
/// removing the task first.
private final class SchemeTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    func register(_ task: URLSessionDataTask, for id: ObjectIdentifier) {
        lock.withLock { tasks[id] = task }
    }

    /// Removes the task and reports whether it was still registered — the
    /// completion handler delivers only then, so a stopped task stays silent.
    func take(_ id: ObjectIdentifier) -> URLSessionDataTask? {
        lock.withLock { tasks.removeValue(forKey: id) }
    }

    func cancel(_ id: ObjectIdentifier) {
        take(id)?.cancel()
    }
}

/// Serves prefetched skin bundles to the game web view and owns their cache.
///
/// The web view host (T7) loads bundle files through the custom scheme
/// ``SkinBundleCache/scheme`` (`digia-skin`), which maps one to one onto the
/// CDN URL — iOS cannot intercept https, so the scheme is the interception
/// point. `schemeURL(forCDNURL:)` builds the URL the host loads;
/// ``SkinBundleCache/webView(_:start:)`` serves a cached file with the
/// contract CSP header and correct mime type, or proxies the CDN when the
/// bundle is incomplete.
///
/// All file state lives under `<Caches>/digia-engage-skins/<sha256 of the
/// bundle folder URL>/`. A bundle is complete only when its marker exists and
/// every manifest file is present with its exact size; anything else reads as
/// not cached, including when the OS has cleared `Caches`.
///
/// Main-actor bound: the `WKURLSchemeHandler` protocol is main-actor
/// isolated, so the whole class is too. File reads are small (one file at
/// most 1 MB); the CDN fallback stays off the main thread.
@MainActor
final class SkinBundleCache: NSObject, WKURLSchemeHandler, @unchecked Sendable {

    /// The custom scheme the web view host loads bundle files through.
    nonisolated static let scheme = "digia-skin"

    /// The fixed CSP header added to every served response (contract B-9.2).
    nonisolated static let contentSecurityPolicy =
        "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; font-src 'self'; media-src 'self'; connect-src 'self'; img-src 'self' https: data:"

    /// Cap for all bundles together: 50 MB, evicted whole-bundle LRU.
    nonisolated static let defaultMaxTotalBytes = 50 * 1024 * 1024

    private static let rootDirectoryName = "digia-engage-skins"
    private static let completionMarkerName = ".digia-complete"

    private let cachesDirectory: URL?
    private let session: URLSession
    private let capBytes: Int
    private let registry = SchemeTaskRegistry()
    private var openKeys = Set<String>()

    /// - Parameters:
    ///   - cachesDirectory: The app's `Caches` directory. Tests pass a
    ///     temporary directory, so they never touch the real one — the same
    ///     pattern as `LocalStorageMigrator.defaultCachesDirectory`.
    ///   - session: Used only for the CDN fallback of an incomplete bundle.
    ///   - maxTotalBytes: The whole-cache cap. Production uses 50 MB; tests
    ///     pass a small cap to observe eviction without downloading 50 MB.
    init(
        cachesDirectory: URL? = SkinBundleCache.defaultCachesDirectory,
        session: URLSession = .shared,
        maxTotalBytes: Int = SkinBundleCache.defaultMaxTotalBytes
    ) {
        self.cachesDirectory = cachesDirectory
        self.session = session
        self.capBytes = maxTotalBytes
    }

    /// The app's caches directory, where the skin bundles live. Tests pass a
    /// temporary directory instead, so they never touch the real one.
    nonisolated static var defaultCachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    // MARK: - Bundle identity

    /// The bundle folder URL for a `bundleUrl` pointing at a file inside it
    /// (normally `.../<skinId>/<version>/index.html`). The SDK never builds a
    /// bundle URL; it derives the folder from the payload's `bundleUrl`.
    nonisolated static func bundleFolderURL(for bundleUrl: URL) -> URL {
        var components = URLComponents(url: bundleUrl, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return (components?.url ?? bundleUrl).deletingLastPathComponent()
    }

    /// The cache key for a bundle folder: sha256 hex, so any host or skin
    /// name maps to a safe directory name.
    nonisolated static func cacheKey(forBundleFolder folder: URL) -> String {
        let digest = SHA256.hash(data: Data(folder.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func cacheKey(forBundleUrl bundleUrl: URL) -> String {
        cacheKey(forBundleFolder: bundleFolderURL(for: bundleUrl))
    }

    /// The `digia-skin` URL the web view host loads for a CDN file URL.
    nonisolated static func schemeURL(forCDNURL cdnURL: URL) -> URL? {
        var components = URLComponents(url: cdnURL, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url
    }

    /// The CDN URL a `digia-skin` request URL maps back to.
    nonisolated static func cdnURL(forSchemeURL schemeURL: URL) -> URL? {
        guard schemeURL.scheme == scheme else { return nil }
        var components = URLComponents(url: schemeURL, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    nonisolated static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Completeness

    /// Whether the bundle is fully cached and verified. A missing folder, a
    /// missing marker, or any file absent or with a wrong size reads as not
    /// cached — including when the OS has cleared `Caches`.
    func isComplete(bundleUrl: URL) -> Bool {
        guard let record = readRecord(forKey: Self.cacheKey(forBundleUrl: bundleUrl)),
              let directory = directoryURL(forKey: record.key)
        else { return false }
        for entry in record.files {
            let fileURL = directory.appendingPathComponent(entry.path)
            guard let size = fileByteCount(at: fileURL), size == entry.size else { return false }
        }
        return true
    }

    /// Marks the bundle open while its surface is showing. An open bundle is
    /// never evicted. The host calls `markClosed` when the surface closes.
    func markOpen(bundleUrl: URL) {
        openKeys.insert(Self.cacheKey(forBundleUrl: bundleUrl))
    }

    func markClosed(bundleUrl: URL) {
        openKeys.remove(Self.cacheKey(forBundleUrl: bundleUrl))
    }

    // MARK: - Install and eviction

    /// Moves a verified staged folder into the cache and marks it complete.
    /// The prefetcher downloads into a temp folder and verifies every size
    /// first, so the cache never holds a partial bundle: it appears atomically
    /// on this move.
    func install(bundleUrl: URL, manifest: SkinBundleManifest, stagedDirectory: URL) throws {
        guard let root = rootDirectory() else { throw SkinCacheError.noCachesDirectory }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = Self.bundleFolderURL(for: bundleUrl)
        let key = Self.cacheKey(forBundleFolder: folder)
        let destination = root.appendingPathComponent(key, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: stagedDirectory, to: destination)
        let record = SkinBundleRecord(
            key: key, folderURL: folder.absoluteString, files: manifest.files, lastUsed: Date())
        try writeRecord(record, forKey: key)
    }

    /// Evicts least-recently-used whole bundles until `bytes` more fit under
    /// the cap. Never evicts `excluding` (the bundle being prefetched) or any
    /// open bundle. Returns false when nothing evictable frees enough room.
    @discardableResult
    func evictIfNeeded(freeingFor bytes: Int, excluding key: String) -> Bool {
        guard rootDirectory() != nil else { return true }
        var entries = scannedEntries()
        var total = entries.reduce(0) { $0 + $1.bytes }
        guard total + bytes > capBytes else { return true }
        for entry in entries.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            if total + bytes <= capBytes { break }
            guard entry.key != key, !openKeys.contains(entry.key) else { continue }
            guard let directory = directoryURL(forKey: entry.key) else { continue }
            try? FileManager.default.removeItem(at: directory)
            total -= entry.bytes
            entries.removeAll { $0.key == entry.key }
        }
        return total + bytes <= capBytes
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let schemeURL = urlSchemeTask.request.url,
              let cdnURL = Self.cdnURL(forSchemeURL: schemeURL)
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        if let (data, mimeType) = cachedResponse(forCDNURL: cdnURL) {
            noteServed(cdnURL: cdnURL)
            let response = HTTPURLResponse(
                url: schemeURL, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mimeType,
                    "Content-Security-Policy": Self.contentSecurityPolicy,
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }
        // Incomplete bundle: fall back to the CDN for this load. The handler
        // owns the task until `stop` cancels it, so delivery is exactly once.
        nonisolated(unsafe) let taskRef = urlSchemeTask
        let id = ObjectIdentifier(taskRef)
        let registry = registry
        let task = session.dataTask(with: cdnURL) { data, response, error in
            guard registry.take(id) != nil else { return }
            if let error {
                taskRef.didFailWithError(error)
                return
            }
            guard let data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                taskRef.didFailWithError(URLError(.badServerResponse))
                return
            }
            let mimeType = http.value(forHTTPHeaderField: "Content-Type")
                ?? Self.mimeType(forPath: cdnURL.path)
            let proxied = HTTPURLResponse(
                url: schemeURL, statusCode: http.statusCode, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mimeType,
                    "Content-Security-Policy": Self.contentSecurityPolicy,
                ]
            )!
            taskRef.didReceive(proxied)
            taskRef.didReceive(data)
            taskRef.didFinish()
        }
        registry.register(task, for: id)
        task.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        registry.cancel(ObjectIdentifier(urlSchemeTask))
    }

    // MARK: - Private

    private func rootDirectory() -> URL? {
        cachesDirectory?.appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
    }

    private func directoryURL(forKey key: String) -> URL? {
        rootDirectory()?.appendingPathComponent(key, isDirectory: true)
    }

    private func fileByteCount(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return nil }
        return size
    }

    private func markerURL(forKey key: String) -> URL? {
        directoryURL(forKey: key)?.appendingPathComponent(Self.completionMarkerName)
    }

    private func readRecord(forKey key: String) -> SkinBundleRecord? {
        guard let markerURL = markerURL(forKey: key),
              let data = try? Data(contentsOf: markerURL),
              let record = try? JSONDecoder().decode(SkinBundleRecord.self, from: data),
              record.key == key
        else { return nil }
        return record
    }

    private func writeRecord(_ record: SkinBundleRecord, forKey key: String) throws {
        guard let markerURL = markerURL(forKey: key) else { throw SkinCacheError.noCachesDirectory }
        let data = try JSONEncoder().encode(record)
        try data.write(to: markerURL, options: .atomic)
    }

    private struct ScannedEntry {
        let key: String
        let bytes: Int
        let lastUsed: Date
        let folderURL: String
    }

    /// Every complete bundle on disk. A folder with an unreadable marker is
    /// its own entry with zero bytes and the oldest date, so junk is evicted
    /// first rather than counted against the cap forever.
    private func scannedEntries() -> [ScannedEntry] {
        guard let root = rootDirectory(),
              let folders = try? FileManager.default.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return [] }
        return folders.map { directory in
            let key = directory.lastPathComponent
            if let record = readRecord(forKey: key) {
                let bytes = record.files.reduce(0) { $0 + max($1.size, 0) }
                return ScannedEntry(key: key, bytes: bytes, lastUsed: record.lastUsed, folderURL: record.folderURL)
            }
            return ScannedEntry(key: key, bytes: 0, lastUsed: .distantPast, folderURL: "")
        }
    }

    /// The cached bytes for a CDN file URL, when a complete bundle covers it.
    private func cachedResponse(forCDNURL cdnURL: URL) -> (Data, String)? {
        let cdnPath = strippedPath(of: cdnURL)
        for entry in scannedEntries() {
            guard !entry.folderURL.isEmpty,
                  let folder = URL(string: entry.folderURL)
            else { continue }
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            guard cdnPath.hasPrefix(prefix) else { continue }
            let relative = String(cdnPath.dropFirst(prefix.count))
            guard !relative.isEmpty,
                  !relative.split(separator: "/").contains(".."),
                  let manifestEntry = readRecord(forKey: entry.key)?.files.first(where: { $0.path == relative }),
                  let directory = directoryURL(forKey: entry.key),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(relative)),
                  data.count == manifestEntry.size
            else { continue }
            return (data, Self.mimeType(forPath: relative))
        }
        return nil
    }

    /// Refreshes LRU time when a cached file is served.
    private func noteServed(cdnURL: URL) {
        let cdnPath = strippedPath(of: cdnURL)
        for entry in scannedEntries() {
            guard !entry.folderURL.isEmpty,
                  let folder = URL(string: entry.folderURL)
            else { continue }
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            guard cdnPath.hasPrefix(prefix), var record = readRecord(forKey: entry.key) else { continue }
            record.lastUsed = Date()
            try? writeRecord(record, forKey: entry.key)
            return
        }
    }

    /// A CDN URL's path without query or fragment, so `?v=` cache-busters
    /// never break the folder match.
    nonisolated private func strippedPath(of url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return (components?.url ?? url).path
    }
}
