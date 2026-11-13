import Foundation
import Testing

@testable import DigiaEngage

/// The T7 slice of the bridge state machine: the ready handshake, the ready
/// timeout, close, and message intake. T8 extends this suite with the play
/// transitions; each test below names the production line that fails it.
@Suite("Game bridge state machine", .tags(.unit, .game))
@MainActor
struct GameBridgeTests {
    private func makeBridge() -> GameBridge {
        GameBridge()
    }

    private func json(_ type: String, extra: [String: String] = [:]) -> String {
        var object = ["type": type]
        for (key, value) in extra { object[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    @Test("ready moves loading to idle and fires onReady once")
    func readyMovesToIdle() {
        let bridge = makeBridge()
        var readyCount = 0
        bridge.onReady = { readyCount += 1 }

        bridge.receive(json("ready"))
        #expect(bridge.state == .idle)
        #expect(readyCount == 1)

        // A second ready is not a second impression. Guards the
        // `state == .loading` check in the ready branch.
        bridge.receive(json("ready"))
        #expect(bridge.state == .idle)
        #expect(readyCount == 1)
    }

    @Test("ready timeout closes a loading session with readyTimeout")
    func timeoutClosesLoading() {
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
    func timeoutNoOpAfterReady() {
        let bridge = makeBridge()
        var failed: GameFailure?
        bridge.onFailed = { failed = $0 }

        let generation = bridge.beginLoading()
        bridge.receive(json("ready"))
        bridge.readyTimeoutFired(generation: generation)

        #expect(bridge.state == .idle)
        #expect(failed == nil)
    }

    @Test("a stale timer generation never closes the new load")
    func staleTimerIgnored() {
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
    func closeExactlyOnce() {
        for initial: GameBridge.State in [.loading, .idle] {
            let bridge = makeBridge()
            if initial == .idle { bridge.receive(json("ready")) }
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
    func closedIgnoresAll() {
        let bridge = makeBridge()
        var readyCount = 0
        var unhandled: [(String, [String: Any])] = []
        bridge.onReady = { readyCount += 1 }
        bridge.onUnhandled = { unhandled.append(($0, $1)) }

        bridge.close()
        bridge.receive(json("ready"))
        bridge.receive(json("playRequested"))

        // Guards the closed check at the top of receive.
        #expect(readyCount == 0)
        #expect(unhandled.isEmpty)
    }

    @Test("playRequested parks on onUnhandled for T8")
    func playRequestedParked() {
        let bridge = makeBridge()
        var unhandled: [(String, [String: Any])] = []
        bridge.onUnhandled = { unhandled.append(($0, $1)) }

        bridge.receive(json("ready"))
        bridge.receive(json("playRequested"))

        #expect(bridge.state == .idle)
        #expect(unhandled.count == 1)
        #expect(unhandled[0].0 == "playRequested")
    }

    @Test("error logs without changing state")
    func errorNoStateChange() {
        let bridge = makeBridge()
        bridge.receive(json("ready"))
        bridge.receive(json("error", extra: ["message": "boom"]))
        #expect(bridge.state == .idle)
    }

    @Test("over-16 KB message is dropped, once flagged")
    func oversizedDropped() {
        let bridge = makeBridge()
        let big = String(repeating: "x", count: GameBridge.maxMessageBytes + 1)

        // Guards the `utf8.count <= maxMessageBytes` check in receive.
        bridge.receive(json("ready", extra: ["pad": big]))
        #expect(bridge.state == .loading)
        #expect(bridge.didRecordDrop)
    }

    @Test("malformed and unknown messages are dropped")
    func badMessagesDropped() {
        let bridge = makeBridge()
        bridge.receive("not json at all")
        bridge.receive(json("teleport"))
        bridge.receive(42)

        #expect(bridge.state == .loading)
        #expect(bridge.didRecordDrop)
    }

    @Test("init script calls window.digiaGame.receive with the payload")
    func initScriptShape() throws {
        let bridge = makeBridge()
        let payload = GameInitPayload(
            safeArea: GameSafeArea(top: 0, right: 0, bottom: 34, left: 0),
            locale: "en-IN"
        )
        let script = try #require(bridge.script(for: payload.message()))

        // Guards the receive-call encoding in script(for:).
        #expect(script.hasPrefix("window.digiaGame.receive("))
        #expect(script.hasSuffix(")"))
        let start = script.index(script.startIndex, offsetBy: "window.digiaGame.receive(".count)
        let jsonText = String(script[start...].dropLast())
        let decoded = try #require(
            try JSONSerialization.jsonObject(
                with: Data(jsonText.utf8)) as? [String: Any])
        #expect(decoded["type"] as? String == "init")
        #expect(decoded["surface"] as? String == "fullScreen")
        #expect(decoded["bridgeVersion"] as? Int == GameBridge.bridgeVersion)
    }
}
