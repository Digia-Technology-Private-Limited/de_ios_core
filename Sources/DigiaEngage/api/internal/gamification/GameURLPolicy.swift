import Foundation
import WebKit

/// URL policy for the game web view: only the pinned bundle folder (served
/// through the custom scheme until the T11 cache owns it) plus https images.
/// Everything else — http, foreign schemes, main-frame https navigations,
/// new windows — is cancelled in `decidePolicyFor`.
enum GameURLPolicy {
    /// The scheme the bundle is served through. iOS cannot intercept https,
    /// so the SDK maps this one to one onto the bundle folder instead.
    static let scheme = "digia-skin"

    /// The fixed CSP from the web view contract, sent on every response the
    /// SDK serves from cache (and, from T11, on every cached response).
    static let contentSecurityPolicy =
        "default-src 'none'; script-src 'self' 'unsafe-inline'; "
        + "style-src 'self' 'unsafe-inline'; font-src 'self'; media-src 'self'; "
        + "connect-src 'self'; img-src 'self' https: data:"

    /// MIME types the SDK serves. Anything else is a 404: a skin that loads
    /// outside its bundle contract stays broken loudly in debug, never
    /// silently executable.
    static func mimeType(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
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
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        default: return nil
        }
    }

    /// Bundle-relative path for a scheme URL (`digia-skin://bundle/index.html`
    /// → `index.html`), or nil when it is not a bundle URL at all.
    static func filePath(for url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        return path.isEmpty ? nil : path
    }

    /// Resolves a relative bundle path against the bundle root. Returns nil
    /// when the resolved file escapes the root (`..`, absolute paths) or is
    /// not a file inside it.
    static func localFile(forRelativePath path: String, bundleRoot: URL) -> URL? {
        let root = bundleRoot.standardizedFileURL
        let resolved = root.appendingPathComponent(path).standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        return resolved
    }

    /// Navigation decision. The entry URL always loads (it is the pinned
    /// bundle, remote until T11). Bundle-scheme URLs load (the handler
    /// enforces the folder scope). Https loads only as subresources — config
    /// and reward images — never as a main-frame navigation, so a link can
    /// never leave the bundle. `targetFrame == nil` is a `window.open` and
    /// is always cancelled.
    static func allowNavigation(
        url: URL,
        entryURL: URL,
        navigationType: WKNavigationType,
        isMainFrame: Bool
    ) -> Bool {
        if url == entryURL { return true }
        if url.scheme == scheme { return true }
        if url.scheme == "https", !isMainFrame || navigationType == .other { return true }
        return false
    }
}
