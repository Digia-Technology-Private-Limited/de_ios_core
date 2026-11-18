import Foundation
import Testing

@testable import DigiaEngage

/// The bridge v1 intake: the `{id?, type, payload}` envelope, typed-request
/// dispatch, `result`/`error` replies, and the ready handshake. Each test names
/// the production line that fails it.
@Suite("Game bridge v1", .tags(.unit, .game))
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
        var failed: GameFailure?
        bridge.onFailed = { failed = $0 }

        let generation = bridge.beginLoading()
        bridge.readyTimeoutFired(generation: generation)

        // Guards the `state == .loading` check in readyTimeoutFired.
        #expect(bridge.state == .closed)
        #expect(failed == .readyTimeout)
    }

    @Test("ready timeout is a no-op once ready arrived")
    func timeoutNoOpAfterReady() throws {
        let bridge = makeBridge()
        var failed: GameFailure?
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
        #expect(bridge.didRecordDrop)
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
        #expect(bridge.didRecordDrop)
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
        #expect(bridge.didRecordDrop)
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
        #expect(bridge.didRecordDrop)
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

        bridge.receive(msg("action", id: "d", payload: ["action": "openLink", "url": "medihub://cart"]))

        guard case .actionOpenLink(_, let op, let url) = requests.first else {
            Issue.record("deep link was not accepted")
            return
        }
        #expect(op == "openLink")
        #expect(url.absoluteString == "medihub://cart")
    }

    @Test("invalid payloads are dropped, or answered invalid with an id")
    func invalidPayloads() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        // No id: dropped — including an unknown haptic style, which the
        // intake filters before the player, so the sink stays untouched.
        bridge.receive(msg("haptics", payload: ["style": "buzz"]))
        bridge.receive(msg("action", payload: ["action": "openLink", "url": "javascript:alert(1)"]))
        bridge.receive(msg("action", payload: ["action": "copy"]))
        // With id: answered invalid.
        bridge.receive(msg("action", id: "c", payload: ["action": "copy"]))
        bridge.receive(msg("action", id: "s", payload: ["steps": "spin"]))
        bridge.receive(msg("sensor.start", id: "t", payload: ["sensor": "lidar"]))
        bridge.receive(msg("storage.get", id: "g", payload: [:]))

        #expect(requests.isEmpty)
        #expect(scripts.count == 4)
        for script in scripts {
            let reply = try received(script)
            let payload = try #require(reply["payload"] as? [String: Any])
            #expect(payload["code"] as? String == "invalid")
        }
        #expect(bridge.didRecordDrop)
    }

    @Test("action steps parse through the canvas parser")
    func actionStepsParse() {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        bridge.onRequest = { requests.append($0) }

        bridge.receive(msg("action", id: "a", payload: ["steps": [
            ["type": "Action.copyToClipBoard", "data": ["text": "CODE"]],
            ["type": "Action.openUrl", "data": ["url": "myapp://bills"]],
        ]]))

        // Guards the steps intake: the bridge reuses the canvas onClick parser.
        #expect(requests.count == 1)
        guard case .actionSteps(let id, let actions) = requests.first else {
            Issue.record("request is not actionSteps")
            return
        }
        #expect(id == "a")
        #expect(actions == [.copyToClipboard("CODE"), .openDeeplink("myapp://bills")])
    }

    @Test("an action without an id runs and gets no reply")
    func actionWithoutIdRunsSilently() {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("action", payload: ["action": "copy", "text": "CODE"]))
        bridge.receive(msg("action", payload: ["steps": [
            ["type": "Action.copyToClipBoard", "data": ["text": "CODE"]],
        ]]))

        // Guards the id-less intake: both forms dispatch, neither is answered.
        #expect(requests.count == 2)
        #expect(scripts.isEmpty)
    }

    @Test("an unknown action form answers unsupported, or is ignored without an id")
    func unknownActionUnsupported() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("action", id: "u", payload: ["action": "explode"]))
        bridge.receive(msg("action", payload: ["action": "explode"]))

        // Guards the unsupported intake: one answered error, one silent ignore.
        #expect(requests.isEmpty)
        #expect(scripts.count == 1)
        let reply = try received(scripts[0])
        let payload = try #require(reply["payload"] as? [String: Any])
        #expect(payload["code"] as? String == "unsupported")
    }

    @Test("an unknown action step answers unsupported")
    func unknownStepUnsupported() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("action", id: "u", payload: ["steps": [
            ["type": "Action.copyToClipBoard", "data": ["text": "CODE"]],
            ["type": "Action.teleport", "data": [:]],
        ]]))

        // Guards the steps validation: nothing runs, the skin hears unsupported.
        #expect(requests.isEmpty)
        #expect(scripts.count == 1)
        let reply = try received(scripts[0])
        let payload = try #require(reply["payload"] as? [String: Any])
        #expect(payload["code"] as? String == "unsupported")
    }

    @Test("action op routing: spec ops and aliases reach the generic handlers")
    func actionOpRouting() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        // Spec ops, plus the shipped `action` names as aliases.
        bridge.receive(msg("action", payload: ["op": "copy", "text": "CODE"]))
        bridge.receive(msg("action", payload: ["action": "copy", "text": "CODE"]))
        bridge.receive(msg("action", payload: ["op": "openUrl", "url": "https://example.com/a"]))
        bridge.receive(msg("action", payload: ["action": "openLink", "url": "https://example.com/a"]))
        bridge.receive(msg("action", payload: ["op": "deeplink", "url": "medihub://cart"]))
        bridge.receive(msg("action", payload: ["op": "customKV", "payload": ["screen": "cart"]]))
        bridge.receive(msg("action", payload: ["op": "share", "text": "won!"]))
        bridge.receive(msg("action", payload: ["op": "close", "reason": "done"]))
        // Spec request aliases.
        bridge.receive(msg("motion", id: "m1", payload: [
            "op": "subscribe", "sensors": ["gyroscope"], "hz": 30,
        ]))
        bridge.receive(msg("motion", id: "m2", payload: ["op": "unsubscribe", "sensors": ["gyroscope"]]))
        bridge.receive(msg("storage", id: "s1", payload: ["op": "get", "key": "hi.score"]))
        // Unknown op answers unsupported; a missing field answers invalid.
        bridge.receive(msg("action", id: "u", payload: ["op": "explode"]))
        bridge.receive(msg("action", id: "c", payload: ["op": "copy"]))
        bridge.receive(msg("storage", id: "s2", payload: ["op": "wipe"]))

        #expect(requests.count == 11)
        if case .actionCopy(_, let text) = requests[0] { #expect(text == "CODE") }
        else { Issue.record("request 0 is not copy") }
        if case .actionCopy(_, let text) = requests[1] { #expect(text == "CODE") }
        else { Issue.record("request 1 is not legacy copy") }
        if case .actionOpenLink(_, let op, let url) = requests[2] {
            #expect(op == "openUrl")
            #expect(url.absoluteString == "https://example.com/a")
        } else { Issue.record("request 2 is not openUrl") }
        if case .actionOpenLink(_, let op, let url) = requests[3] {
            #expect(op == "openLink")
            #expect(url.absoluteString == "https://example.com/a")
        } else { Issue.record("request 3 is not legacy openLink") }
        if case .actionOpenDeeplink(_, let url) = requests[4] {
            #expect(url.absoluteString == "medihub://cart")
        } else { Issue.record("request 4 is not deeplink") }
        if case .actionCustomKV(_, let payload) = requests[5] {
            #expect(payload == ["screen": "cart"])
        } else { Issue.record("request 5 is not customKV") }
        if case .actionShare(_, let text) = requests[6] { #expect(text == "won!") }
        else { Issue.record("request 6 is not share") }
        if case .actionClose(_, let reason) = requests[7] { #expect(reason == "done") }
        else { Issue.record("request 7 is not close") }
        if case .motionSubscribe(let id, let sensors, let hz) = requests[8] {
            #expect(id == "m1")
            #expect(sensors == ["gyroscope"])
            #expect(hz == 30)
        } else { Issue.record("request 8 is not motion subscribe") }
        if case .motionUnsubscribe(let id, let sensors) = requests[9] {
            #expect(id == "m2")
            #expect(sensors == ["gyroscope"])
        } else { Issue.record("request 9 is not motion unsubscribe") }
        if case .storageGet(let id, let key) = requests[10] {
            #expect(id == "s1")
            #expect(key == "hi.score")
        } else { Issue.record("request 10 is not storage get") }

        #expect(scripts.count == 3)
        var codes: [String] = []
        for script in scripts {
            let message = try received(script)
            let payload = try #require(message["payload"] as? [String: Any])
            codes.append(try #require(payload["code"] as? String))
        }
        #expect(codes == ["unsupported", "invalid", "unsupported"])
    }

    @Test("sensor start clamps hz and reports availability names")
    func sensorStartClampsHz() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        bridge.onRequest = { requests.append($0) }

        bridge.receive(msg("sensor.start", id: "1", payload: ["sensor": "gyroscope", "hz": 100]))
        bridge.receive(msg("sensor.start", id: "2", payload: ["sensor": "accelerometer"]))
        bridge.receive(msg("sensor.stop", id: "3", payload: ["sensor": "gyroscope"]))

        #expect(requests.count == 3)
        if case .sensorStart(_, let sensor, let hz) = requests[0] {
            #expect(sensor == "gyroscope")
            #expect(hz == 60)
        } else {
            Issue.record("request 0 is not sensor.start")
        }
        if case .sensorStart(_, _, let hz) = requests[1] {
            #expect(hz == 30)
        } else {
            Issue.record("request 1 is not sensor.start")
        }
        if case .sensorStop(let id, let sensor) = requests[2] {
            #expect(id == "3")
            #expect(sensor == "gyroscope")
        } else {
            Issue.record("request 2 is not sensor.stop")
        }
    }

    @Test("answer and fail shape the result and error replies")
    func replyShapes() throws {
        let bridge = makeBridge()
        var scripts: [String] = []
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("ready"))
        bridge.answer(id: "a", payload: ["started": true])
        bridge.fail(id: "b", code: .forbidden, message: "forbidden path")

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
        #expect(errorPayload["code"] as? String == "forbidden")
        #expect((errorPayload["message"] as? String)?.isEmpty == false)
    }

    @Test("init payload carries the v1 shape through __receive")
    func initMessageShape() throws {
        let bridge = makeBridge()
        var scripts: [String] = []
        bridge.onSend = { scripts.append($0) }

        let device = GameDeviceInfo(
            osVersion: "18.0", sdkVersion: "4.3.2", model: "iPhone17,2",
            locale: "en-IN", timezone: "Asia/Kolkata",
            hapticsAllowed: true, reducedMotion: false,
            tier: "full", ramMb: 8192, cores: 6,
            thermal: "nominal", lowPower: false,
            sensors: ["gyroscope", "accelerometer"])
        let payload = GameInitPayload(
            chanceId: "ch_1", campaignId: "c_1", campaignKey: "bill_pay_spin",
            skinId: "wheel", skinVersion: 3,
            values: ["label": .string("Spin")],
            slots: [GamificationSlotConfig(outcomeKey: "win", values: ["color": "red"])],
            showMute: false,
            viewportWidth: 412, viewportHeight: 915,
            safeArea: GameSafeArea(top: 24, right: 0, bottom: 16, left: 0),
            colorScheme: "light", fontFamily: nil, themeFonts: [],
            device: device)
        bridge.push(type: "init", payload: payload.message())

        #expect(scripts.count == 1)
        let message = try received(scripts[0])
        #expect(message["type"] as? String == "init")
        let body = try #require(message["payload"] as? [String: Any])
        #expect(body["bridgeVersion"] as? Int == GameBridge.bridgeVersion)
        #expect((body["capabilities"] as? [String])?.contains("http") == true)
        #expect(body["chanceId"] as? String == "ch_1")
        let campaign = try #require(body["campaign"] as? [String: Any])
        #expect(campaign["skinVersion"] as? Int == 3)
        let values = try #require(body["values"] as? [String: Any])
        #expect(values["label"] as? String == "Spin")
        let viewport = try #require(body["viewport"] as? [String: Any])
        #expect(viewport["width"] as? Double == 412)
        let devicePayload = try #require(body["device"] as? [String: Any])
        #expect(devicePayload["platform"] as? String == "ios")
        #expect(devicePayload["tier"] as? String == "full")
    }
}
