import Foundation
import WebKit

/// URL policy for the game web view: the pinned cached `index.html` loads from
/// disk through `loadFileURL`, everything else loads only as a subresource —
/// https images and fonts, or files under the bundle root. Anything else —
/// http, foreign schemes, main-frame navigations away from the entry — is
/// cancelled in `decidePolicyFor`.
enum GameUrlPolicy {
    /// Navigation decision. The entry file always loads. Other file URLs load
    /// only as subresources under the bundle root — a single-file skin never
    /// navigates. Https loads only as subresources (config art, reward
    /// images), and only when Android-strict allows the asset: an image, font
    /// or audio extension, or an `Accept: image/...` request for an
    /// extensionless image CDN — never in the main frame, so a link, redirect,
    /// or scripted navigation can never leave the bundle. `targetFrame == nil`
    /// is a `window.open` and is always cancelled. `accept` is the request's
    /// `Accept` header when the host has one; it defaults to nil (strict).
    static func allowNavigation(
        url: URL,
        entryURL: URL,
        bundleRoot: URL,
        navigationType: WKNavigationType,
        isMainFrame: Bool,
        accept: String? = nil
    ) -> Bool {
        if url == entryURL { return true }
        if url.isFileURL {
            guard !isMainFrame else { return false }
            return isUnderRoot(url, bundleRoot)
        }
        if url.scheme?.lowercased() == "https", !isMainFrame {
            return allowsRemoteAsset(url: url, accept: accept)
        }
        return false
    }

    /// Whether a skin bundle may download from `url`: https, or http only when
    /// its origin equals the origin of `apiBaseUrl` (the Test Kit mock serves
    /// skins from its own origin). Scheme and host compare case-insensitively;
    /// a default port is normalized. Never throws.
    static func allowsBundle(_ url: URL, apiBaseUrl: String = DigiaEndpoints.baseUrl) -> Bool {
        guard let origin = normalizedOrigin(url) else { return false }
        if origin.hasPrefix("https://") { return true }
        guard origin.hasPrefix("http://"), let base = URL(string: apiBaseUrl) else { return false }
        return origin == normalizedOrigin(base)
    }

    /// Off-folder https subresources a skin may load: images (config values
    /// and the reward `imageUrl`), web fonts (`init.theme.fonts` URLs) and
    /// sound cues. Mirrors Android `REMOTE_ASSET_EXTENSIONS`, kept in step
    /// with the `img-src`, `font-src` and `media-src` directives of the skin
    /// CSP header.
    private static let remoteAssetExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "svg", "avif", "ico", "bmp",
        "woff", "woff2", "ttf", "otf",
        "mp3", "ogg", "wav", "m4a", "aac",
    ]

    /// Subresource rule (Android-strict): an off-folder https image, font or
    /// audio extension loads; anything else cancels. An extensionless https
    /// URL loads only as an image request carrying `Accept: image/...`,
    /// because image CDNs often serve extensionless URLs (e.g. Cloudinary
    /// `.../f_auto,q_auto/<publicId>`). A URL with a non-media extension
    /// (e.g. `.js`) never passes on Accept alone. The web view sends
    /// `Accept: image/...` only for image loads; `fetch`/XHR default to a
    /// wildcard. Http never passes, even with an image Accept. Never throws.
    static func allowsRemoteAsset(url: URL, accept: String? = nil) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        if remoteAssetExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard url.pathExtension.isEmpty,
              let accept,
              accept.drop(while: \.isWhitespace).lowercased().hasPrefix("image/")
        else { return false }
        return true
    }

    /// `scheme://host[:port]`, lowercased, default port dropped; nil unless http(s) with a host.
    static func normalizedOrigin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        let defaultPort: Int
        switch scheme {
        case "https": defaultPort = 443
        case "http": defaultPort = 80
        default: return nil
        }
        let port = url.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// Whether a file URL resolves inside the bundle root. Returns false when
    /// the resolved file escapes the root (`..`, absolute paths outside it).
    static func isUnderRoot(_ url: URL, _ root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
