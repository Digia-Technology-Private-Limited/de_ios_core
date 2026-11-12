import Foundation
import Testing
import WebKit

@testable import DigiaEngage

/// The T7 URL policy: bundle URLs load, https loads only as subresources
/// (config and reward images), and everything else is cancelled.
@Suite("Game URL policy", .tags(.unit, .game))
struct GameURLPolicyTests {
    private let entry = URL(string: "digia-skin://bundle/index.html")!
    private let remoteEntry = URL(string: "https://cdn.example.com/skins/wheel/1/index.html")!

    @Test("bundle file URLs load")
    func bundleAllowed() {
        let url = URL(string: "digia-skin://bundle/js/game.js")!
        #expect(GameURLPolicy.allowNavigation(
            url: url, entryURL: entry,
            navigationType: .other, isMainFrame: true))
    }

    @Test("https subresources load (images)")
    func httpsSubresourceAllowed() {
        let url = URL(string: "https://cdn.example.com/rewards/coupon.png")!
        #expect(GameURLPolicy.allowNavigation(
            url: url, entryURL: entry,
            navigationType: .other, isMainFrame: true))
    }

    @Test("https main-frame navigation is cancelled")
    func httpsMainFrameDenied() {
        let url = URL(string: "https://cdn.example.com/rewards/coupon.png")!
        // Guards the main-frame check in allowNavigation: a link tap must
        // never leave the bundle.
        #expect(!GameURLPolicy.allowNavigation(
            url: url, entryURL: entry,
            navigationType: .linkActivated, isMainFrame: true))
    }

    @Test("http and foreign schemes are cancelled")
    func foreignDenied() {
        for raw in ["http://cdn.example.com/x.png", "about:blank", "myapp://open"] {
            let url = URL(string: raw)!
            #expect(!GameURLPolicy.allowNavigation(
                url: url, entryURL: entry,
                navigationType: .other, isMainFrame: false))
        }
    }

    @Test("the remote entry loads while the cache is unfilled")
    func remoteEntryAllowed() {
        #expect(GameURLPolicy.allowNavigation(
            url: remoteEntry, entryURL: remoteEntry,
            navigationType: .other, isMainFrame: true))
    }

    @Test("paths escaping the bundle root resolve to nil")
    func escapeRejected() throws {
        let root = try #require(URL(string: "file:///tmp/bundle"))
        #expect(GameURLPolicy.localFile(
            forRelativePath: "../secret.txt", bundleRoot: root) == nil)
        #expect(GameURLPolicy.localFile(
            forRelativePath: "/etc/passwd", bundleRoot: root) == nil)
    }

    @Test("unknown extensions have no MIME type")
    func unknownExtensionNoMime() {
        #expect(GameURLPolicy.mimeType(for: "exe") == nil)
        #expect(GameURLPolicy.mimeType(for: "html") == "text/html")
        #expect(GameURLPolicy.mimeType(for: "JS") == "text/javascript")
    }

    @Test("CSP matches the web view contract value")
    func cspValue() {
        // Guards the CSP constant: the header the scheme handler sends must
        // stay byte-identical to the contract.
        #expect(GameURLPolicy.contentSecurityPolicy
            == "default-src 'none'; script-src 'self' 'unsafe-inline'; "
            + "style-src 'self' 'unsafe-inline'; font-src 'self'; media-src 'self'; "
            + "connect-src 'self'; img-src 'self' https: data:")
    }
}
