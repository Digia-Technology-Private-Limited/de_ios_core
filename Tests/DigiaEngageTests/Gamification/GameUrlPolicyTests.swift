import Foundation
import Testing
import WebKit

@testable import DigiaEngage

/// The file-world URL policy: the cached entry loads, subresources stay
/// under the bundle root, https loads only off the main frame, and everything
/// else is cancelled.
@Suite("Game URL policy", .tags(.unit, .game))
struct GameUrlPolicyTests {
    private let root = URL(string: "file:///tmp/bundle/")!
    private let entry = URL(string: "file:///tmp/bundle/index.html")!

    private func allow(
        _ raw: String, navigationType: WKNavigationType = .other, isMainFrame: Bool = false,
        accept: String? = nil
    ) -> Bool {
        GameUrlPolicy.allowNavigation(
            url: URL(string: raw)!, entryURL: entry, bundleRoot: root,
            navigationType: navigationType, isMainFrame: isMainFrame, accept: accept)
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
        #expect(!GameUrlPolicy.isUnderRoot(URL(string: "file:///tmp/bundle/../secret.txt")!, root))
        #expect(!GameUrlPolicy.isUnderRoot(URL(string: "file:///tmp/other/x.js")!, root))
        #expect(GameUrlPolicy.isUnderRoot(URL(string: "file:///tmp/bundle/a/b.js")!, root))
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

    @Test("https code and data subresources are cancelled")
    func httpsNonMediaCancelled() {
        // Guards the Android-strict rule: a skin can no longer pull
        // code-adjacent content off-host as a subresource.
        for raw in [
            "https://api.example.com/collect.js",
            "https://api.example.com/data.json",
            "https://evil.example.com/index.html",
            "https://cdn.example.com/rewards/coupon.html",
        ] {
            #expect(!allow(raw))
            #expect(!GameUrlPolicy.allowsRemoteAsset(url: URL(string: raw)!))
        }
    }

    @Test("https images, fonts and audio load as subresources, never as navigation")
    func httpsMediaAllowed() {
        // Query strings and uppercase extensions still match, like Android.
        for raw in [
            "https://images.example.com/rewards/coupon.png?size=large",
            "https://cdn.example.com/pic.JPG",
            "https://fonts.example.com/brand.woff2",
            "https://audio.example.com/win.mp3",
        ] {
            #expect(allow(raw))
            #expect(GameUrlPolicy.allowsRemoteAsset(url: URL(string: raw)!))
            // Never in the main frame: art stays a subresource.
            #expect(!allow(raw, navigationType: .linkActivated, isMainFrame: true))
        }
    }

    @Test("extensionless https images load only with an image Accept")
    func extensionlessImageNeedsImageAccept() {
        let cloudinary = "https://res.cloudinary.com/demo/image/upload/f_auto,q_auto/Gift_Box"
        let imgAccept = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
        #expect(allow(cloudinary, accept: imgAccept))
        #expect(GameUrlPolicy.allowsRemoteAsset(url: URL(string: cloudinary)!, accept: imgAccept))
        #expect(!allow(cloudinary, accept: "*/*"))
        #expect(!allow(cloudinary, accept: "text/html"))
        #expect(!allow(cloudinary))
        // The Accept sniff is gated to extensionless URLs: a code URL with an
        // image Accept still cancels.
        #expect(!allow("https://api.example.com/collect.js", accept: imgAccept))
        #expect(!GameUrlPolicy.allowsRemoteAsset(
            url: URL(string: "https://api.example.com/collect.js")!, accept: imgAccept))
        // An extensioned image still loads on its extension (Accept-agnostic).
        #expect(allow("https://cdn.example.com/rewards/coupon.png", accept: imgAccept))
        // Http never passes the sniff, even for an image request.
        #expect(!allow("http://res.cloudinary.com/demo/Gift_Box", accept: imgAccept))
        #expect(!GameUrlPolicy.allowsRemoteAsset(
            url: URL(string: "http://res.cloudinary.com/demo/Gift_Box")!, accept: imgAccept))
    }

    @Test("an http bundle off the API base origin is rejected")
    func httpBundleOffApiBaseRejected() {
        let mock = "http://localhost:8080"
        let skin = "/gamification/skins/w/1/index.html"
        func allowed(_ raw: String, _ base: String = mock) -> Bool {
            GameUrlPolicy.allowsBundle(URL(string: raw)!, apiBaseUrl: base)
        }
        // The TestKit http exception is origin-pinned: another host, another
        // port, or the https API base never serves an http bundle.
        #expect(!allowed("http://127.0.0.1:8080\(skin)"))
        #expect(!allowed("http://cdn.example.com\(skin)"))
        #expect(!allowed("http://localhost:9090\(skin)"))
        #expect(!allowed("http://app.digia.tech\(skin)", "https://app.digia.tech"))
        #expect(allowed("http://localhost:8080\(skin)"))
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
            GameUrlPolicy.allowsBundle(URL(string: raw)!, apiBaseUrl: base)
        }
        // Guards the origin match: only the mock's own origin may serve http.
        #expect(allowed("HTTP://LocalHost:8080\(skin)"))
        #expect(allowed("http://localhost:80\(skin)", "http://localhost"))
        #expect(!allowed("http://127.0.0.1:8080\(skin)"))
        #expect(!allowed("http://localhost:9090\(skin)"))
        #expect(!allowed("http://app.digia.tech\(skin)", "https://app.digia.tech"))
        #expect(allowed("https://cdn.example.com\(skin)"))
    }

    @Test("the bundle origin is derived from the bundle url")
    func bundleOriginDerived() {
        let bundle = URL(string: "https://cdn.example.com/gamification/skins/wheelClassic/1/index.html")!
        // Guards the scheme/host/port normalization: the version folder's
        // origin is the CDN origin the launcher opens.
        #expect(GameUrlPolicy.normalizedOrigin(bundle) == "https://cdn.example.com")
        // An unusable URL has no origin.
        #expect(URL(string: "not a url").flatMap(GameUrlPolicy.normalizedOrigin) == nil)
        // An http bundle off the API base origin never opens: allowsBundle
        // refuses its origin, like Android's empty cdnOrigin.
        #expect(!GameUrlPolicy.allowsBundle(
            URL(string: "http://cdn.example.com/gamification/skins/w/1/index.html")!,
            apiBaseUrl: "https://app.digia.tech"))
    }
}
