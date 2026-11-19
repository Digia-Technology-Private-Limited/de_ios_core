import Foundation
import Testing
import WebKit

@testable import DigiaEngage

/// The file-world URL policy: the cached entry loads, subresources stay
/// under the bundle root, https loads only off the main frame, and everything
/// else is cancelled.
@Suite("Game URL policy", .tags(.unit, .game))
struct GameURLPolicyTests {
    private let root = URL(string: "file:///tmp/bundle/")!
    private let entry = URL(string: "file:///tmp/bundle/index.html")!

    private func allow(
        _ raw: String, navigationType: WKNavigationType = .other, isMainFrame: Bool = false
    ) -> Bool {
        GameURLPolicy.allowNavigation(
            url: URL(string: raw)!, entryURL: entry, bundleRoot: root,
            navigationType: navigationType, isMainFrame: isMainFrame)
    }

    @Test("the cached entry always loads")
    func entryAllowed() {
        #expect(allow(entry.absoluteString, navigationType: .other, isMainFrame: true))
    }

    @Test("file subresources under the root load")
    func fileSubresourceAllowed() {
        // Guards the under-root check: same-folder art loads off-main-frame.
        #expect(allow("file:///tmp/bundle/js/game.js"))
    }

    @Test("file main-frame navigation away from the entry is cancelled")
    func fileMainFrameDenied() {
        #expect(!allow("file:///tmp/bundle/other.html", navigationType: .linkActivated, isMainFrame: true))
    }

    @Test("files escaping the root are rejected")
    func escapeRejected() {
        // Guards isUnderRoot: `..` and sibling trees never load.
        #expect(!GameURLPolicy.isUnderRoot(URL(string: "file:///tmp/bundle/../secret.txt")!, root))
        #expect(!GameURLPolicy.isUnderRoot(URL(string: "file:///tmp/other/x.js")!, root))
        #expect(GameURLPolicy.isUnderRoot(URL(string: "file:///tmp/bundle/a/b.js")!, root))
        #expect(!allow("file:///tmp/other/x.js"))
    }

    @Test("https loads only as a subresource")
    func httpsSubresourceOnly() {
        #expect(allow("https://cdn.example.com/rewards/coupon.png"))
        // Guards the main-frame check: a link tap never leaves the bundle.
        #expect(!allow(
            "https://cdn.example.com/rewards/coupon.png",
            navigationType: .linkActivated, isMainFrame: true))
        // A scripted or redirect main-frame navigation stays inside too.
        #expect(!allow(
            "https://cdn.example.com/rewards/coupon.png",
            navigationType: .other, isMainFrame: true))
    }

    @Test("http and foreign schemes are cancelled")
    func foreignDenied() {
        for raw in ["http://cdn.example.com/x.png", "about:blank", "myapp://open"] {
            #expect(!allow(raw))
        }
    }

    @Test("an http bundle is allowed only from the API base origin")
    func httpBundleOnlyFromApiBase() {
        let mock = "http://localhost:8080"
        let skin = "/gamification/skins/w/1/index.html"
        func allowed(_ raw: String, _ base: String = mock) -> Bool {
            GameURLPolicy.allowsBundle(URL(string: raw)!, apiBaseUrl: base)
        }
        // Guards the origin match: only the mock's own origin may serve http.
        #expect(allowed("HTTP://LocalHost:8080\(skin)"))
        #expect(allowed("http://localhost:80\(skin)", "http://localhost"))
        #expect(!allowed("http://127.0.0.1:8080\(skin)"))
        #expect(!allowed("http://localhost:9090\(skin)"))
        #expect(!allowed("http://app.digia.tech\(skin)", "https://app.digia.tech"))
        #expect(allowed("https://cdn.example.com\(skin)"))
    }
}
