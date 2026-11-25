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

    @Test("motion subscribe with gyroscope and accelerometer passes the intake")
    func motionSubscribeGyroAccelPassIntake() throws {
        let bridge = makeBridge()
        var scripts: [String] = []
        var requests: [GameBridgeRequest] = []
        bridge.onSend = { scripts.append($0) }
        bridge.onRequest = { requests.append($0) }

        bridge.receive(msg("motion", id: "9", payload: [
            "op": "subscribe",
            "sensors": ["gyroscope", "accelerometer"],
            "hz": 30,
        ]))

        // Guards the sensor-name check in handleMotion's subscribe case:
        // only gyroscope + accelerometer pass the intake — a missing sensor
        // answers `unsupported` later at the host, never `bad_request` here.
        #expect(scripts.isEmpty)
        #expect(requests.count == 1)
        if case .motionSubscribe(let id, let sensors, let hz) = requests[0] {
            #expect(id == "9")
            #expect(sensors == ["gyroscope", "accelerometer"])
            #expect(hz == 30)
        } else { Issue.record("request 0 is not motion subscribe") }
    }

    @Test("motion with a non-intake sensor replies bad_request")
    func motionNonIntakeSensorBadRequest() throws {
        let bridge = makeBridge()
        var scripts: [String] = []
        var requests: [GameBridgeRequest] = []
        bridge.onSend = { scripts.append($0) }
        bridge.onRequest = { requests.append($0) }

        // Guards the sensor-name check in handleMotion: the init sensors
        // list still advertises these names, but the intake accepts only
        // gyroscope + accelerometer — each answers bad_request here.
        for name in [
            "gravity", "linear_acceleration", "rotation_vector",
            "magnetic_field", "pressure", "light", "proximity",
        ] {
            bridge.receive(msg("motion", id: "g", payload: ["op": "subscribe", "sensors": [name]]))
            bridge.receive(msg("motion", id: "g", payload: ["op": "unsubscribe", "sensors": [name]]))
        }

        #expect(scripts.count == 14)
        for script in scripts {
            let reply = try received(script)
            let payload = try #require(reply["payload"] as? [String: Any])
            #expect(payload["code"] as? String == "bad_request")
        }
        #expect(requests.isEmpty)
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

    @Test("motion subscribe with an unknown sensor replies bad_request and starts nothing")
    func motionSubscribeUnknownSensorBadRequest() throws {
        let bridge = makeBridge()
        var scripts: [String] = []
        var requests: [GameBridgeRequest] = []
        bridge.onSend = { scripts.append($0) }
        bridge.onRequest = { requests.append($0) }

        bridge.receive(msg("motion", id: "8", payload: ["op": "subscribe", "sensors": ["gyroscope", "magnet"]]))

        // Guards the sensor-name check in handleMotion's subscribe case: a
        // mixed list answers bad_request and no subscribe reaches the host.
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

        bridge.receive(msg("action", id: "d", payload: ["steps": [["type": "deep_link", "data": ["url": "medihub://cart"]]]]))

        guard case .actionSteps(_, let actions) = requests.first else {
            Issue.record("deep link was not accepted")
            return
        }
        #expect(actions == [.openDeeplink("medihub://cart")])
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
        bridge.receive(msg("action", payload: ["steps": [["type": "Action.openUrl", "data": ["url": "javascript:alert(1)", "launchMode": "externalApplication"]]]]))
        bridge.receive(msg("action", payload: ["steps": [["type": "Action.copyToClipBoard", "data": [:]]]]))
        // With id: answered bad_request.
        bridge.receive(msg("action", id: "c", payload: ["steps": [["type": "Action.copyToClipBoard", "data": [:]]]]))
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

    @Test("steps without a named case pass through the canvas parser")
    func actionPassthrough() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("action", id: "a", payload: ["steps": [["type": "Action.requestReview", "data": [:]]]]))
        // A pure dismiss closes through the session.
        bridge.receive(msg("action", id: "d", payload: ["steps": [["type": "Action.dismiss", "data": [:]]]]))
        bridge.receive(msg("action", id: "t", payload: ["steps": [["type": "teleport", "data": [:]]]]))

        // Guards the steps intake: the parser's action reaches the host,
        // the dismiss closes, and the unknown steps answer unsupported.
        #expect(requests.count == 2)
        guard case .actionSteps(let id, let action) = requests.first else {
            Issue.record("request is not actionSteps")
            return
        }
        #expect(id == "a")
        #expect(action == [.requestReview])
        guard case .actionClose(let closeId, _) = requests[1] else {
            Issue.record("dismiss did not close")
            return
        }
        #expect(closeId == "d")
        #expect(scripts.count == 1)
        for script in scripts {
            let payload = try #require(try received(script)["payload"] as? [String: Any])
            #expect(payload["code"] as? String == "unsupported")
        }
    }

    @Test("action steps exclude canvas-only stage actions")
    func actionPassthroughExcludesCanvasOnly() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        // A skin cannot page its host's stage or open another game: every
        // canvas-only step answers unsupported and nothing reaches the host.
        // Dismiss is the one exception: a pure dismiss closes (tested above).
        let types = ["next", "previous", "Action.openGame", "Action.showStory"]
        for (index, type) in types.enumerated() {
            bridge.receive(msg("action", id: "x\(index)", payload: ["steps": [["type": type, "data": [:]]]]))
        }

        // Guards the exclusion list.
        #expect(requests.isEmpty)
        #expect(scripts.count == types.count)
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

        bridge.receive(msg("action", payload: ["steps": [["type": "Action.copyToClipBoard", "data": ["text": "CODE"]]]]))
        bridge.receive(msg("action", payload: ["steps": [["type": "Action.requestReview", "data": [:]]]]))

        // Guards the id-less intake: both forms dispatch, neither is answered.
        #expect(requests.count == 2)
        #expect(scripts.isEmpty)
    }

    @Test("an unknown step answers unsupported, or is dropped without an id")
    func unknownActionUnsupported() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("action", id: "u", payload: ["steps": [["type": "teleport", "data": [:]]]]))
        bridge.receive(msg("action", payload: ["steps": [["type": "teleport", "data": [:]]]]))

        // Guards the unsupported intake: one answered error, one drop.
        #expect(requests.isEmpty)
        #expect(scripts.count == 1)
        let reply = try received(scripts[0])
        let payload = try #require(reply["payload"] as? [String: Any])
        #expect(payload["code"] as? String == "unsupported")
    }

    @Test("action steps routing: canvas steps reach the generic handlers")
    func actionOpRouting() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("action", payload: ["steps": [["type": "Action.copyToClipBoard", "data": ["text": "CODE"]]]]))
        bridge.receive(msg("action", payload: ["steps": [["type": "Action.openUrl", "data": ["url": "https://example.com/a", "launchMode": "externalApplication"]]]]))
        bridge.receive(msg("action", payload: ["steps": [["type": "deep_link", "data": ["url": "medihub://cart"]]]]))
        bridge.receive(msg("action", payload: ["steps": [["type": "Action.customKV", "data": ["payload": ["screen": "cart"]]]]]))
        bridge.receive(msg("action", payload: ["steps": [["type": "Action.share", "data": ["text": "won!"]]]]))
        bridge.receive(msg("action", payload: ["steps": [["type": "Action.dismiss", "data": [:]]]]))
        // Motion and storage requests.
        bridge.receive(msg("motion", id: "m1", payload: [
            "op": "subscribe", "sensors": ["gyroscope"], "hz": 30,
        ]))
        bridge.receive(msg("motion", id: "m2", payload: ["op": "unsubscribe", "sensors": ["gyroscope"]]))
        bridge.receive(msg("storage", id: "s1", payload: ["op": "get", "key": "hi.score"]))
        // Unknown step answers unsupported; a missing field answers bad_request.
        bridge.receive(msg("action", id: "u", payload: ["steps": [["type": "teleport", "data": [:]]]]))
        bridge.receive(msg("action", id: "c", payload: ["steps": [["type": "Action.copyToClipBoard", "data": [:]]]]))
        bridge.receive(msg("storage", id: "s2", payload: ["op": "wipe"]))

        #expect(requests.count == 9)
        if case .actionSteps(_, let actions) = requests[0] { #expect(actions == [.copyToClipboard("CODE")]) }
        else { Issue.record("request 0 is not copy") }
        if case .actionSteps(_, let actions) = requests[1] {
            #expect(actions == [.openUrl("https://example.com/a")])
        } else { Issue.record("request 1 is not openUrl") }
        if case .actionSteps(_, let actions) = requests[2] {
            #expect(actions == [.openDeeplink("medihub://cart")])
        } else { Issue.record("request 2 is not deeplink") }
        if case .actionSteps(_, let actions) = requests[3] {
            #expect(actions == [.customKV(["screen": "cart"])])
        } else { Issue.record("request 3 is not customKV") }
        if case .actionSteps(_, let actions) = requests[4] { #expect(actions == [.share("won!")]) }
        else { Issue.record("request 4 is not share") }
        if case .actionClose = requests[5] { }
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

    @Test("a duplicate http id and a ninth in-flight call reply bad_request with health")
    func duplicateHttpIdAndNinthInFlightReject() throws {
        // The cap is pinned as a literal so widening it fails this test.
        #expect(GameHttpBridge.maxHttpInFlight == 8)

        // A reused id rejects without running.
        let duplicate = try #require(GameHttpBridge.inFlightRejection(
            id: "h0", method: "POST", path: "play",
            inFlightIds: ["h0"]))
        // A ninth call rejects without running.
        let full = Set((0..<8).map { "h\($0)" })
        let ninth = try #require(GameHttpBridge.inFlightRejection(
            id: "h8", method: "POST", path: "play",
            inFlightIds: full))
        // A fresh id under the cap runs.
        let seventh = Set((0..<7).map { "h\($0)" })
        #expect(GameHttpBridge.inFlightRejection(
            id: "h7", method: "POST", path: "play",
            inFlightIds: seventh) == nil)

        // Guards the inFlightRejection leg: both rejects answer bad_request
        // and report game_http_failed with no status, through the same
        // rejectedCall mapping production uses.
        #expect(duplicate == ninth)
        for failed in [duplicate, ninth] {
            #expect(failed.code == .badRequest)
            #expect(failed.status == nil)
            #expect(failed == GameHttpBridge.rejectedCall(method: "POST", path: "play", code: .badRequest))
        }
    }

    @Test("the configured intake cap drops what the default would accept")
    func configuredIntakeCap() {
        // Guards the messageMaxBytes init: a session with a configured
        // bridgeMessageMaxBytes drops past it, never parsing.
        let bridge = GameBridge(messageMaxBytes: 32)
        var drops: [(reason: String, type: String?)] = []
        var requests: [GameBridgeRequest] = []
        bridge.onDropped = { drops.append(($0, $1)) }
        bridge.onRequest = { requests.append($0) }

        bridge.receive(String(repeating: "x", count: 33))

        #expect(requests.isEmpty)
        #expect(drops.count == 1)
        #expect(drops.first?.reason == "oversize")
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
