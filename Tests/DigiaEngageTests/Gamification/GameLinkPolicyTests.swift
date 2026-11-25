import Foundation
import Testing

@testable import DigiaEngage

/// Locks the one link-safety rule every surface shares: web links need a
/// host, the script/local schemes never open, and any other scheme is an app
/// deep link the host handles. The game bridge and the rewards page both call
/// `GameLinkPolicy.isOpenableLink`. Mirrors Android's `GameLinkPolicyTest`.
@Suite("Game link policy", .tags(.unit, .game))
struct GameLinkPolicyTests {
    private func openable(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        return GameLinkPolicy.isOpenableLink(url)
    }

    // Fails if a web link without a host stops being refused, or a plain web
    // link stops opening: the http(s) branch of `isOpenableLink`.
    @Test("web links open only with a host")
    func webLinksNeedHost() {
        #expect(openable("https://example.org/deal"))
        #expect(openable("http://example.org/deal"))
        #expect(openable("HTTPS://Example.org/x"))
        #expect(!openable("https://"))
        #expect(!openable("https:///x"))
        #expect(!openable("http://?q=1"))
    }

    // Fails if a blocked scheme stops being refused on every surface: the
    // shared `blockedLinkSchemes`, covering `about` too (an `about:blank`
    // page is never a destination the host can route).
    @Test("blocked schemes never open in any case")
    func blockedSchemesNeverOpen() {
        for raw in [
            "javascript:alert(1)", "JavaScript:alert(1)", "vbscript:msgbox(1)",
            "data:text/html;base64,AAAA", "blob:https://x/abc", "file:///etc/hosts",
            "content://com.x/file", "about:blank", "ABOUT:blank",
            "intent://scan/#Intent;scheme=zxing;end",
        ] {
            #expect(!openable(raw), "\(raw)")
        }
    }

    // Fails if an app deep link stops opening: every other scheme is the
    // host's routing.
    @Test("any other scheme is an openable app link")
    func otherSchemesOpen() {
        for raw in [
            "myapp://offers/42", "medihub://cart", "tel:+911234567890",
            "mailto:a@b.com", "market://details?id=x",
        ] {
            #expect(openable(raw), "\(raw)")
        }
    }

    // Fails if a schemeless or malformed link stops being refused: no scheme,
    // no routing.
    @Test("links with no scheme or no host never open")
    func schemeRequired() {
        for raw in ["", "   ", "/offers/42", "offers/42", "example.org", "://x"] {
            #expect(!openable(raw), "\(raw)")
        }
    }
}
