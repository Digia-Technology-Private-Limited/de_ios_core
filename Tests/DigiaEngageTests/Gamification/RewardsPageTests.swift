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

    @Test("a custom scheme link is internal")
    func customSchemeInternal() {
        #expect(RewardsLinkRouter.route("myapp://offers/12") == .internal(URL(string: "myapp://offers/12")!))
    }

    @Test("an http(s) link on an app link host is internal, others are external")
    func universalLink() {
        let hosts: Set<String> = ["app.example.com"]
        let own = URL(string: "https://App.example.com/offers")!
        let other = URL(string: "https://shop.example.org/x")!
        #expect(RewardsLinkRouter.route(own.absoluteString, appLinkHosts: hosts) == .internal(own))
        #expect(RewardsLinkRouter.route(other.absoluteString, appLinkHosts: hosts) == .external(other))
        #expect(RewardsLinkRouter.route("http://shop.example.org") == .external(URL(string: "http://shop.example.org")!))
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
        platform: "ios", sdkVersion: "1.2.3", appVersion: "4.5", deviceId: "d1", locale: "en-US")

    @Test("init carries every field the page reads")
    func initShape() throws {
        let message = RewardsBridge.initMessage(context)
        #expect(message["type"] as? String == "init")
        let payload = try #require(message["payload"] as? [String: String])
        #expect(payload == [
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
            deviceId: bare.deviceId, locale: bare.locale)
        let payload = try #require(RewardsBridge.initMessage(bare)["payload"] as? [String: String])
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
