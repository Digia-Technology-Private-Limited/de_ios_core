import CoreGraphics
import Foundation
import Testing

@testable import DigiaEngage

/// The bridge v2 intake: the `{id?, type, payload}` envelope, typed-request
/// dispatch, `result`/`error` replies, and the ready handshake. Each test names
/// the production line that fails it.
@Suite("Game bridge v2", .tags(.unit, .game))
@MainActor
struct GameBridgeTests {
    private func makeBridge() -> GameBridge {
        GameBridge()
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func msg(_ type: String, id: String? = nil, payload: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": type, "payload": payload]
        if let id { object["id"] = id }
        return json(object)
    }

    /// Decodes one `window.DigiaBridge.__receive(...)` script back to its message.
    private func received(_ script: String) throws -> [String: Any] {
        let prefix = "window.DigiaBridge.__receive("
        #expect(script.hasPrefix(prefix))
        #expect(script.hasSuffix(")"))
        let start = script.index(script.startIndex, offsetBy: prefix.count)
        let literal = String(script[start...].dropLast())
        let literalData = try #require(literal.data(using: .utf8))
        let encoded = try JSONDecoder().decode(String.self, from: literalData)
        let messageData = try #require(encoded.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: messageData) as? [String: Any])
    }

    @Test("a second ready re-fires without a second onReady")
    func repeatedReadyResends() throws {
        let bridge = makeBridge()
        var readyCount = 0
        var repeatedCount = 0
        bridge.onReady = { _ in readyCount += 1 }
        bridge.onRepeatedReady = { _ in repeatedCount += 1 }

        bridge.receive(msg("ready"))
        bridge.receive(msg("ready"))

        // Guards the state check around onReady/onRepeatedReady.
        #expect(readyCount == 1)
        #expect(repeatedCount == 1)
        #expect(bridge.state == .idle)
    }

    @Test("ready timeout closes a loading session with readyTimeout")
    func timeoutClosesLoading() throws {
        let bridge = makeBridge()
        var failed: GameFailureReason?
        bridge.onFailed = { failed = $0 }

        let generation = bridge.beginLoading()
        bridge.readyTimeoutFired(generation: generation)

        // Guards the `state == .loading` check in readyTimeoutFired.
        #expect(bridge.state == .closed)
        #expect(failed == .readyTimeout)
    }

    @Test("the commit re-arm makes the load timer stale; the ready timer then fails readyTimeout")
    func commitHandsLoadTimerToReadyTimer() throws {
        let bridge = makeBridge()
        var failed: GameFailureReason?
        bridge.onFailed = { failed = $0 }

        let loadGeneration = bridge.beginLoading()
        let readyGeneration = bridge.beginLoading()
        // Guards the generation check: the 15 s load timer armed before the
        // commit must not close a page that already committed.
        bridge.loadTimeoutFired(generation: loadGeneration)
        #expect(bridge.state == .loading)
        #expect(failed == nil)

        bridge.readyTimeoutFired(generation: readyGeneration)
        #expect(failed == .readyTimeout)
    }

    @Test("ready timeout is a no-op once ready arrived")
    func timeoutNoOpAfterReady() throws {
        let bridge = makeBridge()
        var failed: GameFailureReason?
        bridge.onFailed = { failed = $0 }

        let generation = bridge.beginLoading()
        bridge.receive(msg("ready"))
        bridge.readyTimeoutFired(generation: generation)

        #expect(bridge.state == .idle)
        #expect(failed == nil)
    }

    @Test("close from loading or open lands in closed, then everything is ignored")
    func closeExactlyOnce() throws {
        for initial: GameBridge.State in [.loading, .idle] {
            let bridge = makeBridge()
            if initial == .idle { bridge.receive(msg("ready")) }
            var closedCount = 0
            var readyCount = 0
            var requests: [GameBridgeRequest] = []
            bridge.onClosed = { closedCount += 1 }
            bridge.onReady = { _ in readyCount += 1 }
            bridge.onRequest = { requests.append($0) }

            bridge.close()
            bridge.close()
            bridge.receive(msg("ready"))
            bridge.receive(msg("http", id: "1", payload: ["method": "POST", "path": "play"]))

            // Guards the `state != .closed` check in close and the closed
            // check at the top of receive.
            #expect(bridge.state == .closed)
            #expect(closedCount == 1)
            #expect(readyCount == 0)
            #expect(requests.isEmpty)
        }
    }

    @Test("over-limit message drops through the real entry, once")
    func oversizedDropped() throws {
        let bridge = makeBridge()
        var drops: [(reason: String, type: String?)] = []
        bridge.onDropped = { drops.append(($0, $1)) }
        let big = String(repeating: "x", count: GameBridge.maxMessageBytes + 1)

        // Guards the size check in receive: an oversize skin message never
        // parses, and the first one reports game_bridge_dropped{reason:oversize}.
        bridge.receive(msg("ready", payload: ["pad": big]))
        #expect(bridge.state == .loading)
        #expect(bridge.dropNoted)
        #expect(drops.count == 1)
        #expect(drops.first?.reason == "oversize")
        #expect(drops.first?.type == nil)

        // A second oversize is still a drop, but reports nothing more.
        bridge.receive(msg("ready", payload: ["pad": big]))
        #expect(drops.count == 1)
    }

    @Test("malformed messages are dropped")
    func badMessagesDropped() throws {
        let bridge = makeBridge()
        bridge.receive("not json at all")
        bridge.receive(42)
        bridge.receive(json(["type": 7]))
        bridge.receive(json(["notype": true]))

        #expect(bridge.state == .loading)
        #expect(bridge.dropNoted)
    }

    @Test("unknown type with an id answers unsupported")
    func unknownTypeAnswersUnsupported() throws {
        let bridge = makeBridge()
        var scripts: [String] = []
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("teleport", id: "7"))

        // Guards the unknown-type branch of receive.
        #expect(scripts.count == 1)
        let reply = try received(scripts[0])
        let payload = try #require(reply["payload"] as? [String: Any])
        #expect(payload["code"] as? String == "unsupported")
    }

    @Test("motion with an unknown sensor replies bad_request")
    func motionUnknownSensorBadRequest() throws {
        let bridge = makeBridge()
        var scripts: [String] = []
        var requests: [GameBridgeRequest] = []
        bridge.onSend = { scripts.append($0) }
        bridge.onRequest = { requests.append($0) }

        bridge.receive(msg("motion", id: "7", payload: ["op": "unsubscribe", "sensors": ["magnet"]]))

        // Guards the sensor-name check in handleMotion's unsubscribe case: an
        // unknown name answers bad_request and nothing is stopped.
        #expect(scripts.count == 1)
        let reply = try received(scripts[0])
        let payload = try #require(reply["payload"] as? [String: Any])
        #expect(payload["code"] as? String == "bad_request")
        #expect(requests.isEmpty)
    }

    @Test("unknown type without an id drops with the health event")
    func unknownTypeWithoutIdDrops() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var drops: [(reason: String, type: String?)] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onDropped = { drops.append(($0, $1)) }

        bridge.receive(msg("teleport"))

        // Guards the id-less unsupported drop: flagged once, with the type,
        // so the presenter reports game_bridge_dropped{reason:unknown}.
        #expect(requests.isEmpty)
        #expect(bridge.dropNoted)
        #expect(drops.count == 1)
        #expect(drops.first?.reason == "unknown")
        #expect(drops.first?.type == "teleport")
    }

    @Test("id-less invalid and unsupported messages drop with the health event")
    func idlessRejectsDrop() {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var drops: [(reason: String, type: String?)] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onDropped = { drops.append(($0, $1)) }

        // Guards every id-less reject path: each flags the drop once with
        // reason unknown and the type that was read, so the presenter reports
        // game_bridge_dropped for malformed skins instead of undercounting.
        bridge.receive(msg("action", payload: ["op": "explode"]))
        bridge.receive(msg("action", payload: ["op": "copy"]))
        bridge.receive(msg("motion", payload: ["op": "subscribe"]))
        bridge.receive(msg("storage", payload: ["op": "wipe"]))

        #expect(requests.isEmpty)
        #expect(bridge.dropNoted)
        #expect(drops.count == 1)
        #expect(drops.first?.reason == "unknown")
        #expect(drops.first?.type == "action")
    }

    // Fails if openLink goes back to http(s)-only: the contract routes app deep links through the host.
    @Test("openLink accepts app deep links")
    func openLinkAcceptsDeepLinks() {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        bridge.onRequest = { requests.append($0) }

        bridge.receive(msg("action", id: "d", payload: ["op": "openLink", "url": "medihub://cart"]))

        guard case .actionOpenLink(_, let op, let url) = requests.first else {
            Issue.record("deep link was not accepted")
            return
        }
        #expect(op == "openLink")
        #expect(url.absoluteString == "medihub://cart")
    }

    @Test("invalid payloads are dropped, or answered bad_request with an id")
    func invalidPayloads() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        // No id: dropped — including an unknown haptic style, which the
        // intake filters before the player, so the sink stays untouched.
        bridge.receive(msg("haptics", payload: ["style": "buzz"]))
        bridge.receive(msg("action", payload: ["op": "openLink", "url": "javascript:alert(1)"]))
        bridge.receive(msg("action", payload: ["op": "copy"]))
        // With id: answered bad_request.
        bridge.receive(msg("action", id: "c", payload: ["op": "copy"]))
        bridge.receive(msg("action", id: "s", payload: [:]))
        bridge.receive(msg("motion", id: "t", payload: ["op": "subscribe", "sensors": ["lidar"]]))
        bridge.receive(msg("storage", id: "g", payload: ["op": "get"]))

        #expect(requests.isEmpty)
        #expect(scripts.count == 4)
        for script in scripts {
            let reply = try received(script)
            let payload = try #require(reply["payload"] as? [String: Any])
            #expect(payload["code"] as? String == "bad_request")
        }
        #expect(bridge.dropNoted)
    }

    @Test("an op without a named case passes through the canvas parser")
    func actionPassthrough() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("action", id: "a", payload: ["op": "requestReview"]))
        // Canvas-only actions stay out: a skin cannot dismiss the stage.
        bridge.receive(msg("action", id: "d", payload: ["op": "Action.dismiss"]))
        bridge.receive(msg("action", id: "t", payload: ["op": "Action.teleport"]))

        // Guards passthroughAction: the parser's action reaches the host,
        // the excluded and unknown ops answer unsupported.
        #expect(requests.count == 1)
        guard case .actionPassthrough(let id, let op, let action) = requests.first else {
            Issue.record("request is not actionPassthrough")
            return
        }
        #expect(id == "a")
        #expect(op == "requestReview")
        #expect(action == .requestReview)
        #expect(scripts.count == 2)
        for script in scripts {
            let payload = try #require(try received(script)["payload"] as? [String: Any])
            #expect(payload["code"] as? String == "unsupported")
        }
    }

    @Test("an action without an id runs and gets no reply")
    func actionWithoutIdRunsSilently() {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("action", payload: ["op": "copy", "text": "CODE"]))
        bridge.receive(msg("action", payload: ["op": "requestReview"]))

        // Guards the id-less intake: both forms dispatch, neither is answered.
        #expect(requests.count == 2)
        #expect(scripts.isEmpty)
    }

    @Test("an unknown op answers unsupported, or is dropped without an id")
    func unknownActionUnsupported() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("action", id: "u", payload: ["op": "explode"]))
        bridge.receive(msg("action", payload: ["op": "explode"]))

        // Guards the unsupported intake: one answered error, one drop.
        #expect(requests.isEmpty)
        #expect(scripts.count == 1)
        let reply = try received(scripts[0])
        let payload = try #require(reply["payload"] as? [String: Any])
        #expect(payload["code"] as? String == "unsupported")
    }

    @Test("action op routing: named ops reach the generic handlers")
    func actionOpRouting() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("action", payload: ["op": "copy", "text": "CODE"]))
        bridge.receive(msg("action", payload: ["op": "openUrl", "url": "https://example.com/a"]))
        bridge.receive(msg("action", payload: ["op": "deeplink", "url": "medihub://cart"]))
        bridge.receive(msg("action", payload: ["op": "customKV", "payload": ["screen": "cart"]]))
        bridge.receive(msg("action", payload: ["op": "share", "text": "won!"]))
        bridge.receive(msg("action", payload: ["op": "close", "reason": "done"]))
        // Motion and storage requests.
        bridge.receive(msg("motion", id: "m1", payload: [
            "op": "subscribe", "sensors": ["gyroscope"], "hz": 30,
        ]))
        bridge.receive(msg("motion", id: "m2", payload: ["op": "unsubscribe", "sensors": ["gyroscope"]]))
        bridge.receive(msg("storage", id: "s1", payload: ["op": "get", "key": "hi.score"]))
        // Unknown op answers unsupported; a missing field answers bad_request.
        bridge.receive(msg("action", id: "u", payload: ["op": "explode"]))
        bridge.receive(msg("action", id: "c", payload: ["op": "copy"]))
        bridge.receive(msg("storage", id: "s2", payload: ["op": "wipe"]))

        #expect(requests.count == 9)
        if case .actionCopy(_, let text) = requests[0] { #expect(text == "CODE") }
        else { Issue.record("request 0 is not copy") }
        if case .actionOpenLink(_, let op, let url) = requests[1] {
            #expect(op == "openUrl")
            #expect(url.absoluteString == "https://example.com/a")
        } else { Issue.record("request 1 is not openUrl") }
        if case .actionOpenDeeplink(_, let url) = requests[2] {
            #expect(url.absoluteString == "medihub://cart")
        } else { Issue.record("request 2 is not deeplink") }
        if case .actionCustomKV(_, let payload) = requests[3] {
            #expect(payload == ["screen": "cart"])
        } else { Issue.record("request 3 is not customKV") }
        if case .actionShare(_, let text) = requests[4] { #expect(text == "won!") }
        else { Issue.record("request 4 is not share") }
        if case .actionClose(_, let reason) = requests[5] { #expect(reason == "done") }
        else { Issue.record("request 5 is not close") }
        if case .motionSubscribe(let id, let sensors, let hz) = requests[6] {
            #expect(id == "m1")
            #expect(sensors == ["gyroscope"])
            #expect(hz == 30)
        } else { Issue.record("request 6 is not motion subscribe") }
        if case .motionUnsubscribe(let id, let sensors) = requests[7] {
            #expect(id == "m2")
            #expect(sensors == ["gyroscope"])
        } else { Issue.record("request 7 is not motion unsubscribe") }
        if case .storageGet(let id, let key) = requests[8] {
            #expect(id == "s1")
            #expect(key == "hi.score")
        } else { Issue.record("request 8 is not storage get") }

        #expect(scripts.count == 3)
        var codes: [String] = []
        for script in scripts {
            let message = try received(script)
            let payload = try #require(message["payload"] as? [String: Any])
            codes.append(try #require(payload["code"] as? String))
        }
        #expect(codes == ["unsupported", "bad_request", "unsupported"])
    }

    @Test("answer and fail shape the result and error replies")
    func replyShapes() throws {
        let bridge = makeBridge()
        var scripts: [String] = []
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("ready"))
        bridge.answer(id: "a", payload: ["started": true])
        bridge.fail(id: "b", code: .badRequest, message: "path not allowed")

        #expect(scripts.count == 2)
        let result = try received(scripts[0])
        #expect(result["id"] as? String == "a")
        #expect(result["type"] as? String == "result")
        let resultPayload = try #require(result["payload"] as? [String: Any])
        #expect(resultPayload["started"] as? Bool == true)

        let error = try received(scripts[1])
        #expect(error["id"] as? String == "b")
        #expect(error["type"] as? String == "error")
        let errorPayload = try #require(error["payload"] as? [String: Any])
        #expect(errorPayload["code"] as? String == "bad_request")
        #expect((errorPayload["message"] as? String)?.isEmpty == false)
    }

    @Test("init payload carries the v2 shape through __receive")
    func initMessageShape() throws {
        let bridge = makeBridge()
        var scripts: [String] = []
        bridge.onSend = { scripts.append($0) }

        let device = GameDeviceInfo(
            osVersion: "18.0", sdkVersion: "4.3.2", model: "iPhone17,2",
            locale: "en-IN", timezone: "Asia/Kolkata",
            hapticsAllowed: true, reducedMotion: false,
            tier: "high", ramMb: 8192, cores: 6,
            thermal: "nominal", lowPower: false,
            sensors: ["gyroscope", "accelerometer"])
        let payload = GameInitPayload(
            chanceId: "ch_1", campaignId: "c_1", campaignKey: "bill_pay_spin",
            skinId: "wheel", skinVersion: 3,
            values: ["label": .string("Spin")],
            slots: [GamificationSlotConfig(outcomeKey: "win", values: ["color": .string("red")])],
            viewportWidth: 412, viewportHeight: 915,
            safeArea: GameSafeArea(top: 24, right: 0, bottom: 16, left: 0),
            keyboardBottom: 291,
            colorScheme: "light", fontFamily: nil, themeFonts: [],
            device: device)
        bridge.push(type: "init", payload: payload.message())

        #expect(scripts.count == 1)
        let message = try received(scripts[0])
        #expect(message["type"] as? String == "init")
        let body = try #require(message["payload"] as? [String: Any])
        #expect(body["bridgeVersion"] as? Int == GameBridge.bridgeVersion)
        #expect(body["capabilities"] == nil)
        #expect(body["chanceId"] as? String == "ch_1")
        let campaign = try #require(body["campaign"] as? [String: Any])
        #expect(campaign["skinVersion"] as? Int == 3)
        let values = try #require(body["values"] as? [String: Any])
        #expect(values["label"] as? String == "Spin")
        let viewport = try #require(body["viewport"] as? [String: Any])
        #expect(viewport["width"] as? Double == 412)
        let keyboardInset = try #require(viewport["keyboardInset"] as? [String: Any])
        #expect(keyboardInset["bottom"] as? Double == 291)
        let devicePayload = try #require(body["device"] as? [String: Any])
        #expect(devicePayload["platform"] as? String == "ios")
        #expect(devicePayload["tier"] as? String == "high")
    }
}

/// Text input inside the game: the keyboard inset the `viewport` push
/// carries, and the selection lockdown lifted only for inputs.
@Suite("Game text input", .tags(.unit, .game))
struct GameTextInputTests {
    private let surface = CGRect(x: 0, y: 0, width: 390, height: 844)

    @Test("keyboard inset is the docked keyboard's overlap, 0 when hidden or floating")
    func keyboardInset() {
        // Docked: rises 336 pt from the bottom edge.
        #expect(GameKeyboardInset.bottom(
            keyboard: CGRect(x: 0, y: 508, width: 390, height: 336), surface: surface) == 336)
        // Hidden: the end frame sits below the screen.
        #expect(GameKeyboardInset.bottom(
            keyboard: CGRect(x: 0, y: 844, width: 390, height: 336), surface: surface) == 0)
        // Floating (iPad): does not touch the bottom edge, covers nothing to pad.
        #expect(GameKeyboardInset.bottom(
            keyboard: CGRect(x: 40, y: 300, width: 320, height: 250), surface: surface) == 0)
        // Hardware keyboard: only the 55 pt shortcut bar is docked.
        #expect(GameKeyboardInset.bottom(
            keyboard: CGRect(x: 0, y: 789, width: 390, height: 55), surface: surface) == 55)
    }

    @Test("selection and callout are lifted only for text inputs")
    func selectionScopedToInputs() {
        let css = GameWebViewConfigurationFactory.selectionStyle
        let rules = css.components(separatedBy: "} ")
        #expect(rules.count == 2)
        #expect(rules[0].hasPrefix("* {"))
        #expect(rules[0].contains("user-select: none"))
        #expect(rules[0].contains("-webkit-touch-callout: none"))
        #expect(rules[1].hasPrefix("input, textarea, [contenteditable], [contenteditable] * {"))
        #expect(rules[1].contains("user-select: text"))
        #expect(rules[1].contains("-webkit-touch-callout: default"))
        // Sits inside a single-quoted JS literal unescaped.
        #expect(!css.contains("'") && !css.contains("\\"))
    }
}
