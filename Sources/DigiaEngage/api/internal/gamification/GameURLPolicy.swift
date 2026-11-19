import Foundation
import WebKit

/// URL policy for the game web view: the pinned cached `index.html` loads from
/// disk through `loadFileURL`, everything else loads only as a subresource —
/// https images and fonts, or files under the bundle root. Anything else —
/// http, foreign schemes, main-frame navigations away from the entry — is
/// cancelled in `decidePolicyFor`.
enum GameURLPolicy {
    /// Navigation decision. The entry file always loads. Other file URLs load
    /// only as subresources under the bundle root — a single-file skin never
    /// navigates. Https loads only as subresources (config art, reward
    /// images), never in the main frame, so a link, redirect, or scripted
    /// navigation can never leave the bundle. `targetFrame == nil` is a
    /// `window.open` and is always cancelled.
    static func allowNavigation(
        url: URL,
        entryURL: URL,
        bundleRoot: URL,
        navigationType: WKNavigationType,
        isMainFrame: Bool
    ) -> Bool {
        if url == entryURL { return true }
        if url.isFileURL {
            guard !isMainFrame else { return false }
            return isUnderRoot(url, bundleRoot)
        }
        if url.scheme == "https", !isMainFrame { return true }
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

    /// `scheme://host[:port]`, lowercased, default port dropped; nil unless http(s) with a host.
    private static func normalizedOrigin(_ url: URL) -> String? {
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
