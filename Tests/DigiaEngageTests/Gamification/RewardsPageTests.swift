import Foundation
import Testing

@testable import DigiaEngage

/// The web rewards page's SDK side: link routing, the bridge wire format, and
/// the web view's navigation policy. Each test names the production line that
/// fails it.
@Suite("Rewards page", .tags(.unit, .game))
@MainActor
struct RewardsPageTests {
    // MARK: - Link router

    @Test("script, data, file, blob, vbscript and intent links are refused")
    func refusedSchemes() {
        for raw in [
            "javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,hi", "file:///etc/passwd",
            "blob:https://x.com/1", "vbscript:run", "intent://x#Intent;end", "not a url", "",
        ] {
            #expect(RewardsLinkRouter.route(raw) == .refused, "\(raw)")
        }
    }

    @Test("an http(s) link is external, whatever the host")
    func webLinkExternal() {
        for raw in ["https://shop.example.org/x", "http://shop.example.org", "HTTPS://App.example.com/offers",
                    " https://example.com/a "] {
            let url = URL(string: raw.trimmingCharacters(in: .whitespaces))!
            #expect(RewardsLinkRouter.route(raw) == .external(url), "\(raw)")
        }
    }

    @Test("an http(s) link with no host is refused")
    func webLinkNeedsHost() {
        for raw in ["https://", "http:///path", "https:/path"] {
            #expect(RewardsLinkRouter.route(raw) == .refused, "\(raw)")
        }
    }

    @Test("any other allowed scheme is internal: custom, partner, tel, mailto")
    func otherSchemesInternal() {
        for raw in ["myapp://offers/12", "MyApp://offers/12", "ridenow://trip/1", "tel:+911234567890",
                    "mailto:a@b.com", "whatsapp://send?text=hi"] {
            #expect(RewardsLinkRouter.route(raw) == .internal(URL(string: raw)!), "\(raw)")
        }
    }

    // MARK: - Game layer ownership

    @Test("the root cover shows games unless a rewards page owns the layer")
    func gameLayerOwnership() {
        GameLayerOwner.resetForTesting()
        defer { GameLayerOwner.resetForTesting() }
        let gameObject = NSObject(), openObject = NSObject()
        let game = ObjectIdentifier(gameObject), open = ObjectIdentifier(openObject)
        defer { withExtendedLifetime((gameObject, openObject)) {} }
        #expect(GameLayerOwner.layer(for: game) == .root)
        let token = GameLayerOwner.claim(existingGame: open)
        #expect(GameLayerOwner.layer(for: game) == .rewards)
        #expect(GameLayerOwner.layer(for: open) == .root)
        GameLayerOwner.release(token)
        #expect(GameLayerOwner.layer(for: game) == .root)
    }

    @Test("a stale page cannot release a newer claim")
    func staleRelease() {
        GameLayerOwner.resetForTesting()
        defer { GameLayerOwner.resetForTesting() }
        let game = ObjectIdentifier(NSObject())
        let old = GameLayerOwner.claim(existingGame: nil)
        let new = GameLayerOwner.claim(existingGame: nil)
        GameLayerOwner.release(old)
        #expect(GameLayerOwner.layer(for: game) == .rewards)
        GameLayerOwner.release(new)
        #expect(GameLayerOwner.layer(for: game) == .root)
    }

    @Test("a claim whose page is gone is dropped and the root cover shows games")
    func deadClaimIsDropped() {
        GameLayerOwner.resetForTesting()
        defer { GameLayerOwner.resetForTesting() }
        let gameObject = NSObject()
        let game = ObjectIdentifier(gameObject)
        defer { withExtendedLifetime(gameObject) {} }
        var live = true
        _ = GameLayerOwner.claim(existingGame: nil, isLive: { live })
        #expect(GameLayerOwner.layer(for: game) == .rewards)
        live = false
        #expect(GameLayerOwner.layer(for: game) == .root)
        live = true
        #expect(GameLayerOwner.layer(for: game) == .root)
    }

    @Test("the page error forwarder sends message, source and line only")
    func errorForwarder() {
        let script = RewardsPageViewController.errorForwardScript
        #expect(script.contains("digiaPageError"))
        #expect(script.contains("unhandledrejection"))
        #expect(script.contains("e.filename") && script.contains("e.lineno"))
    }

    // MARK: - Bridge

    private func page(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func action(_ op: String, _ payload: [String: Any] = [:]) -> String {
        page(["type": "action", "payload": payload.merging(["op": op]) { current, _ in current }])
    }

    @Test("page messages parse")
    func parsesPageMessages() {
        #expect(RewardsBridge.parse(page(["type": "ready", "payload": [String: Any]()])) == .ready)
        #expect(RewardsBridge.parse(action("loadFailed")) == .loadFailed)
        #expect(RewardsBridge.parse(action("close")) == .close)
        #expect(RewardsBridge.parse(action("copy", ["text": "SAVE10"])) == .copy("SAVE10"))
        #expect(RewardsBridge.parse(action("openLink", ["url": "myapp://x"])) == .openLink("myapp://x"))
        #expect(
            RewardsBridge.parse(action("openGame", ["chanceId": "c1", "campaignId": "k1"]))
                == .openGame(chanceId: "c1", campaignId: "k1"))
    }

    @Test("navState parses a real boolean only")
    func navState() {
        #expect(RewardsBridge.parse(action("navState", ["canGoBack": true])) == .navState(canGoBack: true))
        #expect(RewardsBridge.parse(action("navState", ["canGoBack": false])) == .navState(canGoBack: false))
        #expect(RewardsBridge.parse(action("navState", ["canGoBack": 1])) == nil)
        #expect(RewardsBridge.parse(action("navState")) == nil)
    }

    @Test("back goes to the page only while it is shown and can go back")
    func backDecision() {
        typealias Page = RewardsPageViewController
        #expect(Page.shouldGoBack(canGoBack: true, state: .ready))
        #expect(!Page.shouldGoBack(canGoBack: false, state: .ready))
        #expect(!Page.shouldGoBack(canGoBack: true, state: .loading))
        #expect(!Page.shouldGoBack(canGoBack: true, state: .offline))
        #expect(RewardsBridge.script(for: RewardsBridge.backMessage)
            == "window.DigiaBridge.__receive(\"{\\\"payload\\\":{},\\\"type\\\":\\\"back\\\"}\")")
    }

    @Test("malformed, incomplete and unknown page messages are dropped")
    func dropsBadMessages() {
        #expect(RewardsBridge.parse(nil) == nil)
        #expect(RewardsBridge.parse("not json") == nil)
        #expect(RewardsBridge.parse(page(["type": "init"])) == nil)
        #expect(RewardsBridge.parse(action("openGame", ["chanceId": "c1"])) == nil)
        #expect(RewardsBridge.parse(action("openLink", ["url": "  "])) == nil)
        #expect(RewardsBridge.parse(action("copy")) == nil)
        #expect(RewardsBridge.parse(action("share", ["text": "x"])) == nil)
        let oversize = action("copy", ["text": String(repeating: "a", count: GameBridge.maxMessageBytes)])
        #expect(RewardsBridge.parse(oversize) == nil)
    }

    private let context = RewardsBridge.Context(
        apiBase: "https://app.digia.tech/api/v1", projectId: "p1", userId: "u1", userHash: "h1",
        platform: "ios", sdkVersion: "1.2.3", appVersion: "4.5", deviceId: "d1", locale: "en-US",
        insets: .init(top: 47, bottom: 34, left: 0, right: 0))

    @Test("init carries every field the page reads")
    func initShape() throws {
        let message = RewardsBridge.initMessage(context)
        #expect(message["type"] as? String == "init")
        let payload = try #require(message["payload"] as? [String: Any])
        let insets = try #require(payload["insets"] as? [String: Double])
        #expect(insets == ["top": 47, "bottom": 34, "left": 0, "right": 0])
        let strings = payload.filter { $0.key != "insets" }.compactMapValues { $0 as? String }
        #expect(strings == [
            "apiBase": "https://app.digia.tech/api/v1", "projectId": "p1", "userId": "u1",
            "userHash": "h1", "platform": "ios", "sdkVersion": "1.2.3", "appVersion": "4.5",
            "deviceId": "d1", "locale": "en-US",
        ])
    }

    @Test("init leaves out an unset userHash")
    func initWithoutHash() throws {
        var bare = context
        bare = RewardsBridge.Context(
            apiBase: bare.apiBase, projectId: bare.projectId, userId: bare.userId, userHash: nil,
            platform: bare.platform, sdkVersion: bare.sdkVersion, appVersion: bare.appVersion,
            deviceId: bare.deviceId, locale: bare.locale, insets: bare.insets)
        let payload = try #require(RewardsBridge.initMessage(bare)["payload"] as? [String: Any])
        #expect(payload["userHash"] == nil)
    }

    @Test("init and refresh go out as DigiaBridge.__receive scripts")
    func scripts() throws {
        let initScript = try #require(RewardsBridge.script(for: RewardsBridge.initMessage(context)))
        #expect(initScript.hasPrefix("window.DigiaBridge.__receive(\""))
        #expect(initScript.contains("apiBase"))
        let refresh = try #require(RewardsBridge.script(for: RewardsBridge.refreshMessage))
        #expect(refresh == "window.DigiaBridge.__receive(\"{\\\"payload\\\":{},\\\"type\\\":\\\"refresh\\\"}\")")
    }

    @Test("insets go out as their own message")
    func insetsMessage() throws {
        let message = RewardsBridge.insetsMessage(.init(top: 59, bottom: 34, left: 0, right: 0))
        #expect(message["type"] as? String == "insets")
        #expect(message["payload"] as? [String: Double] == ["top": 59, "bottom": 34, "left": 0, "right": 0])
    }

    @Test("the locale is a BCP-47 tag")
    func locale() {
        #expect(RewardsBridge.bcp47Locale(preferred: ["en_US"]) == "en-US")
        #expect(RewardsBridge.bcp47Locale(preferred: ["hi-IN", "en-US"]) == "hi-IN")
        #expect(RewardsBridge.bcp47Locale(preferred: []) == "en-US")
    }

    // MARK: - Page URL and navigation policy

    @Test("the page URL is the backend's https address, else the environment default")
    func pageUrl() {
        #expect(RewardsPageURL.resolve(pageUrl: "https://rewards.example.com/", environment: .production)
            == URL(string: "https://rewards.example.com/")!)
        #expect(RewardsPageURL.resolve(pageUrl: nil, environment: .production)
            == URL(string: "https://rewards.digia.tech")!)
        #expect(RewardsPageURL.resolve(pageUrl: "http://rewards.example.com", environment: .sandbox)
            == URL(string: "https://rewards-dev.digia.tech")!)
        #expect(RewardsPageURL.resolve(pageUrl: "javascript:1", environment: .sandbox)
            == URL(string: "https://rewards-dev.digia.tech")!)
    }

    private let pageURL = URL(string: "https://rewards.digia.tech/")!

    private func allow(_ raw: String, hasTargetFrame: Bool = true) -> Bool {
        RewardsPageURL.allowNavigation(url: URL(string: raw)!, pageURL: pageURL, hasTargetFrame: hasTargetFrame)
    }

    @Test("navigation stays inside the page origin")
    func navigationPolicy() {
        #expect(allow("https://rewards.digia.tech/?x=1"))
        #expect(allow("https://REWARDS.digia.tech:443/a"))
        #expect(!allow("https://evil.example.com/"))
        #expect(!allow("http://rewards.digia.tech/"))
        #expect(!allow("https://rewards.digia.tech:8443/"))
        #expect(!allow("file:///etc/passwd"))
        #expect(!allow("about:blank"))
        #expect(!allow("myapp://x"))
        #expect(!allow("https://rewards.digia.tech/", hasTargetFrame: false))
    }

    @Test("a page address of nil allows nothing")
    func noPageUrl() {
        #expect(!RewardsPageURL.allowNavigation(
            url: pageURL, pageURL: nil, hasTargetFrame: true))
    }

    @Test("an HTTP error status on the main frame is a failed load")
    func httpError() {
        func response(_ status: Int) -> URLResponse {
            HTTPURLResponse(url: pageURL, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        #expect(RewardsPageURL.isHttpError(response(404)))
        #expect(RewardsPageURL.isHttpError(response(503)))
        #expect(!RewardsPageURL.isHttpError(response(200)))
        #expect(!RewardsPageURL.isHttpError(URLResponse(url: pageURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)))
    }

    // MARK: - getRewards page.url

    @Test("getRewards page.url is read")
    func readsPageUrl() {
        let raw: [String: Any] = ["page": ["url": "https://rewards.digia.tech"]]
        #expect(GameRewardsResponse.fromJson(raw).pageUrl == "https://rewards.digia.tech")
        #expect(GameRewardsResponse.fromJson([:]).pageUrl == nil)
    }
}
