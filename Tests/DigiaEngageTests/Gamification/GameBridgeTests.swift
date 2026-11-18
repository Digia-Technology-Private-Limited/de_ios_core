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

    @Test("ready never answers, even with an id")
    func readyNeverAnswers() throws {
        let bridge = makeBridge()
        var versions: [Int] = []
        var scripts: [String] = []
        bridge.onReady = { versions.append($0) }
        bridge.onSend = { scripts.append($0) }

        bridge.receive(msg("ready", id: "r1", payload: ["bridgeVersion": 1]))
        #expect(bridge.state == .idle)
        #expect(versions == [1])

        // A ready never gets a reply, even with an id.
        #expect(scripts.isEmpty)
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

    @Test("ready reports a newer skin version for the presentation to refuse")
    func readyReportsNewerVersion() throws {
        let bridge = makeBridge()
        var versions: [Int] = []
        bridge.onReady = { versions.append($0) }

        bridge.receive(msg("ready", payload: ["bridgeVersion": 2]))
        #expect(versions == [2])
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

    @Test("a stale timer generation never closes the new load")
    func staleTimerIgnored() throws {
        let bridge = makeBridge()
        var failed: GameFailure?
        bridge.onFailed = { failed = $0 }

        let first = bridge.beginLoading()
        let second = bridge.beginLoading()
        bridge.readyTimeoutFired(generation: first)

        // Guards the generation check in readyTimeoutFired.
        #expect(bridge.state == .loading)
        #expect(failed == nil)

        bridge.readyTimeoutFired(generation: second)
        #expect(bridge.state == .closed)
        #expect(failed == .readyTimeout)
    }

    @Test("close settles exactly once from any open state")
    func closeExactlyOnce() throws {
        for initial: GameBridge.State in [.loading, .idle] {
            let bridge = makeBridge()
            if initial == .idle { bridge.receive(msg("ready")) }
            var closedCount = 0
            bridge.onClosed = { closedCount += 1 }

            bridge.close()
            bridge.close()

            // Guards the `state != .closed` check in close.
            #expect(bridge.state == .closed)
            #expect(closedCount == 1)
        }
    }

    @Test("messages in closed are ignored")
    func closedIgnoresAll() throws {
        let bridge = makeBridge()
        var readyCount = 0
        var requests: [GameBridgeRequest] = []
        bridge.onReady = { _ in readyCount += 1 }
        bridge.onRequest = { requests.append($0) }

        bridge.close()
        bridge.receive(msg("ready"))
        bridge.receive(msg("http", id: "1", payload: ["method": "POST", "path": "play"]))

        // Guards the closed check at the top of receive.
        #expect(readyCount == 0)
        #expect(requests.isEmpty)
    }

    @Test("over-limit message is dropped, once flagged")
    func oversizedDropped() throws {
        let bridge = makeBridge()
        let big = String(repeating: "x", count: GameBridge.maxMessageBytes + 1)

        // Guards the `utf8.count <= maxMessageBytes` check in receive.
        bridge.receive(msg("ready", payload: ["pad": big]))
        #expect(bridge.state == .loading)
        #expect(bridge.didRecordDrop)
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

    @Test("missing type with an id answers invalid")
    func missingTypeAnswersInvalid() throws {
        let bridge = makeBridge()
        var scripts: [String] = []
        bridge.onSend = { scripts.append($0) }

        bridge.receive(json(["id": "9", "payload": [:]]))

        // Guards the missing-type branch: a request is never left hanging.
        #expect(scripts.count == 1)
        let reply = try received(scripts[0])
        #expect(reply["id"] as? String == "9")
        #expect(reply["type"] as? String == "error")
        let payload = try #require(reply["payload"] as? [String: Any])
        #expect(payload["code"] as? String == "invalid")
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

    @Test("http parses method, path and optional body")
    func httpParses() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        bridge.onRequest = { requests.append($0) }

        bridge.receive(msg("http", id: "1", payload: ["method": "post", "path": "play", "body": ["a": 1]]))
        bridge.receive(msg("http", id: "2", payload: ["method": "GET", "path": "rewards"]))
        // No id means no possible reply: dropped.
        bridge.receive(msg("http", payload: ["method": "GET", "path": "rewards"]))

        #expect(requests.count == 2)
        if case .http(let id, let method, let path, let body) = requests[0] {
            #expect(id == "1")
            #expect(method == "post")
            #expect(path == "play")
            #expect(body?["a"] as? Int == 1)
        } else {
            Issue.record("first request is not http")
        }
        if case .http(let id, _, let path, let body) = requests[1] {
            #expect(id == "2")
            #expect(path == "rewards")
            #expect(body == nil)
        } else {
            Issue.record("second request is not http")
        }
        #expect(bridge.didRecordDrop)
    }

    @Test("event, log, haptics and actions parse")
    func notificationsParse() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        bridge.onRequest = { requests.append($0) }

        bridge.receive(msg("event", id: "e", payload: ["name": "spin", "props": ["x": 1]]))
        bridge.receive(msg("log", payload: ["level": "warn", "message": "m"]))
        bridge.receive(msg("haptics", payload: ["style": "error"]))
        bridge.receive(msg("action", payload: ["action": "copy", "text": "CODE"]))
        bridge.receive(msg("action", id: "o", payload: ["action": "openLink", "url": "https://example.com/a"]))
        bridge.receive(msg("action", payload: ["action": "close", "reason": "done"]))

        #expect(requests.count == 6)
        if case .event(let id, let name, let props) = requests[0] {
            #expect(id == "e")
            #expect(name == "spin")
            #expect(props["x"] as? Int == 1)
        } else {
            Issue.record("request 0 is not event")
        }
        if case .log(_, let level, let message) = requests[1] {
            #expect(level == "warn")
            #expect(message == "m")
        } else {
            Issue.record("request 1 is not log")
        }
        if case .haptics(_, let style) = requests[2] {
            #expect(style == "error")
        } else {
            Issue.record("request 2 is not haptics")
        }
        if case .actionCopy(_, let text) = requests[3] {
            #expect(text == "CODE")
        } else {
            Issue.record("request 3 is not copy")
        }
        if case .actionOpenLink(let id, let url) = requests[4] {
            #expect(id == "o")
            #expect(url.absoluteString == "https://example.com/a")
        } else {
            Issue.record("request 4 is not openLink")
        }
        if case .actionClose(_, let reason) = requests[5] {
            #expect(reason == "done")
        } else {
            Issue.record("request 5 is not close")
        }
    }

    // Fails if openLink goes back to http(s)-only: the contract routes app deep links through the host.
    @Test("openLink accepts app deep links")
    func openLinkAcceptsDeepLinks() {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        bridge.onRequest = { requests.append($0) }

        bridge.receive(msg("action", id: "d", payload: ["action": "openLink", "url": "medihub://cart"]))

        guard case .actionOpenLink(_, let url) = requests.first else {
            Issue.record("deep link was not accepted")
            return
        }
        #expect(url.absoluteString == "medihub://cart")
    }

    @Test("invalid payloads are dropped, or answered invalid with an id")
    func invalidPayloads() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        // No id: dropped, except haptics which forwards without a reply.
        bridge.receive(msg("haptics", payload: ["style": "buzz"]))
        bridge.receive(msg("action", payload: ["action": "openLink", "url": "javascript:alert(1)"]))
        bridge.receive(msg("action", payload: ["action": "copy"]))
        // With id: answered invalid.
        bridge.receive(msg("action", id: "c", payload: ["action": "copy"]))
        bridge.receive(msg("action", id: "s", payload: ["steps": "spin"]))
        bridge.receive(msg("sensor.start", id: "t", payload: ["sensor": "lidar"]))
        bridge.receive(msg("storage.get", id: "g", payload: [:]))

        #expect(requests.count == 1)
        if case .haptics(_, let style) = requests.first {
            #expect(style == "buzz")
        } else {
            Issue.record("haptics buzz was not forwarded")
        }
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
        if case .actionOpenLink(_, let url) = requests[2] {
            #expect(url.absoluteString == "https://example.com/a")
        } else { Issue.record("request 2 is not openUrl") }
        if case .actionOpenLink(_, let url) = requests[3] {
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

    @Test("empty copy and share text answers invalid, or is dropped without an id")
    func emptyCopyShareInvalid() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        // Guards the non-blank text check: Android rejects empty text too.
        bridge.receive(msg("action", id: "c", payload: ["op": "copy", "text": ""]))
        bridge.receive(msg("action", id: "s", payload: ["op": "share", "text": ""]))
        // Whitespace-only text still runs, like Android's isEmpty check.
        bridge.receive(msg("action", id: "w", payload: ["op": "copy", "text": " "]))
        bridge.receive(msg("action", payload: ["op": "copy", "text": ""]))

        #expect(requests.count == 1)
        if case .actionCopy(let id, let text) = requests.first {
            #expect(id == "w")
            #expect(text == " ")
        } else {
            Issue.record("whitespace copy was not accepted")
        }
        #expect(scripts.count == 2)
        for script in scripts {
            let reply = try received(script)
            let payload = try #require(reply["payload"] as? [String: Any])
            #expect(payload["code"] as? String == "invalid")
        }
        #expect(bridge.didRecordDrop)
    }

    @Test("motion unsubscribe needs a non-empty sensor list")
    func motionUnsubscribeRequiresSensors() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        // Guards the parity rule: an id-less unsubscribe has no reply path,
        // an empty or missing list answers invalid like Android.
        bridge.receive(msg("motion", id: "u1", payload: ["op": "unsubscribe"]))
        bridge.receive(msg("motion", id: "u2", payload: ["op": "unsubscribe", "sensors": []]))
        bridge.receive(msg("motion", id: "u3", payload: ["op": "unsubscribe", "sensors": ["lidar"]]))
        bridge.receive(msg("motion", id: "u4", payload: [
            "op": "unsubscribe", "sensors": ["gyroscope", "accelerometer"],
        ]))

        #expect(requests.count == 1)
        if case .motionUnsubscribe(let id, let sensors) = requests.first {
            #expect(id == "u4")
            #expect(sensors == ["gyroscope", "accelerometer"])
        } else {
            Issue.record("valid unsubscribe was not accepted")
        }
        #expect(scripts.count == 3)
        for script in scripts {
            let reply = try received(script)
            let payload = try #require(reply["payload"] as? [String: Any])
            #expect(payload["code"] as? String == "invalid")
        }
    }

    @Test("id-less storage remove still runs, get and set do not")
    func idlessStorageRemoveRuns() {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        bridge.onRequest = { requests.append($0) }
        bridge.onSend = { scripts.append($0) }

        // Guards the Android parity: an id-less remove runs with no reply;
        // id-less get and set are dropped without effect.
        bridge.receive(msg("storage", payload: ["op": "remove", "key": "hi.score"]))
        bridge.receive(msg("storage", payload: ["op": "get", "key": "hi.score"]))
        bridge.receive(msg("storage", payload: ["op": "set", "key": "hi.score", "value": "1"]))
        bridge.receive(msg("storage.remove", payload: ["key": "hi.score"]))

        #expect(requests.count == 2)
        for request in requests {
            guard case .storageRemove(let id, let key) = request else {
                Issue.record("id-less remove was not forwarded")
                return
            }
            #expect(id == nil)
            #expect(key == "hi.score")
        }
        // No reply path exists without an id.
        #expect(scripts.isEmpty)
        #expect(bridge.didRecordDrop)
    }

    @Test("init advertises the steps capability")
    func initAdvertisesSteps() {
        // Guards the capability: skins feature-detect action.steps.
        #expect(GameInitPayload.capabilities.contains("action.steps"))
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

    @Test("storage requests parse key and value")
    func storageParses() throws {
        let bridge = makeBridge()
        var requests: [GameBridgeRequest] = []
        bridge.onRequest = { requests.append($0) }

        bridge.receive(msg("storage.set", id: "1", payload: ["key": "hi.score", "value": "42"]))
        bridge.receive(msg("storage.get", id: "2", payload: ["key": "hi.score"]))
        bridge.receive(msg("storage.remove", id: "3", payload: ["key": "hi.score"]))

        #expect(requests.count == 3)
        if case .storageSet(let id, let key, let value) = requests[0] {
            #expect(id == "1")
            #expect(key == "hi.score")
            #expect(value == "42")
        } else {
            Issue.record("request 0 is not storage.set")
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
