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

    /// Whether a file URL resolves inside the bundle root. Returns false when
    /// the resolved file escapes the root (`..`, absolute paths outside it).
    static func isUnderRoot(_ url: URL, _ root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
