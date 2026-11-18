import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Wire error codes for `{id, type:"error"}` replies.
enum GameBridgeErrorCode: String, Sendable, Error {
    case network
    case timeout
    case forbidden
    case unsupported
    case invalid
    case quota
    case `internal`
}

/// One typed skin→native message the presentation handles. `event`, `log`
/// and `haptics` never get a reply, even with an id; `ready` never reaches
/// here.
enum GameBridgeRequest {
    case http(id: String, method: String, path: String, body: [String: Any]?)
    case event(id: String?, name: String, props: [String: Any])
    case log(id: String?, level: String, message: String)
    case haptics(id: String?, style: String)
    case sensorStart(id: String, sensor: String, hz: Double)
    case sensorStop(id: String, sensor: String)
    case storageGet(id: String, key: String)
    case storageSet(id: String, key: String, value: String)
    case storageRemove(id: String, key: String)
    case actionCopy(id: String?, text: String)
    case actionOpenLink(id: String?, url: URL)
    case actionOpenDeeplink(id: String?, url: URL)
    case actionShare(id: String?, text: String)
    case actionCustomKV(id: String?, payload: [String: String])
    case actionClose(id: String?, reason: String?)
    case motionSubscribe(id: String, sensors: [String], hz: Double)
    case motionUnsubscribe(id: String, sensors: [String])
    /// Canvas steps sent over the bridge (`payload.steps`, the same `onClick`
    /// object a canvas element carries). Unknown steps never reach here — the
    /// intake answers them as `unsupported`.
    case actionSteps(id: String?, actions: [EngageAction])
}

/// Owns the bridge intake: the `{id?, type, payload}` envelope, the ready
/// handshake, the ready timeout, and close. Typed requests go to `onRequest`;
/// replies and pushes go out through `onSend` as `window.DigiaBridge.__receive`
/// scripts. Anything else is dropped and logged, never thrown — malformed
/// input on a render path must degrade, per the workspace guidelines.
///
/// Unknown `type` with an `id` answers `error unsupported`; unknown without an
/// id is ignored + logged. A request-shaped message the bridge cannot answer
/// (no usable id) is dropped.
@MainActor
final class GameBridge {
    /// The SDK's bridge version. Informational: any skin version is
    /// accepted.
    nonisolated static let bridgeVersion = 1
    /// Seconds from load start to `ready` before the container closes quietly.
    nonisolated static let readyTimeoutSeconds = 5.0
    /// Skin messages above this many UTF-8 bytes are dropped, never parsed. Fits a
    /// full 16 KB `storage.set` value or `http` body plus its envelope.
    nonisolated static let maxMessageBytes = 64 * 1024

    enum State: Equatable {
        case loading
        case idle
        case closed
    }

    private(set) var state: State = .loading
    /// Set once per session by the first dropped message.
    private(set) var didRecordDrop = false

    /// Fires once, when `ready` moves `loading` → `idle`, with the skin's
    /// declared bridge version. A version above ``GameBridge/bridgeVersion``
    /// is refused by the presentation.
    var onReady: (@MainActor (Int) -> Void)?
    /// Fires on every `ready` past the first, with the declared version: the
    /// same init is re-sent.
    var onRepeatedReady: (@MainActor (Int) -> Void)?
    /// Fires once, when the first message is dropped, with the reason
    /// (`oversize`, `malformed` or `unknown`) and the request type when one
    /// was read. The presentation reports it as `game_bridge_dropped`.
    var onDropped: (@MainActor (String, String?) -> Void)?
    /// Fires once, when the session reaches `closed` via close or teardown.
    /// Timeout close fires `onFailed` instead — never both.
    var onClosed: (@MainActor () -> Void)?
    /// Fires once, when the session closes as a failure.
    var onFailed: (@MainActor (GameFailure) -> Void)?
    /// One parsed request per skin message the bridge accepts.
    var onRequest: (@MainActor (GameBridgeRequest) -> Void)?
    /// One full `window.DigiaBridge.__receive(...)` script per reply or push.
    /// The presentation evaluates it on the main actor.
    var onSend: (@MainActor (String) -> Void)?

    /// Message types the intake accepts by `type`. Anything else is unknown.
    private static let knownTypes: Set<String> = [
        "ready", "http", "event", "log", "haptics",
        "sensor.start", "sensor.stop",
        "storage.get", "storage.set", "storage.remove",
        "motion", "storage", "action",
    ]

    /// (Re)enters `loading`. Returns a generation token so the one-shot ready
    /// timer fires only for the load that armed it.
    private var generation = 0

    func beginLoading() -> Int {
        state = .loading
        generation += 1
        return generation
    }

    /// The entry point for `digia.postMessage`. Never throws: a bad message is
    /// a drop and a log, never a crash on a render path.
    func receive(_ body: Any?) {
        guard state != .closed else { return }
        guard let text = body as? String,
              text.utf8.count <= Self.maxMessageBytes,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let reason: String = {
                guard let text = body as? String else { return "malformed" }
                return text.utf8.count > Self.maxMessageBytes ? "oversize" : "malformed"
            }()
            recordDrop(reason: reason)
            return
        }
        let id = object["id"] as? String
        guard let type = object["type"] as? String else {
            // No route exists, but a request still gets its exactly-once answer.
            if let id { fail(id: id, code: .invalid, message: "message has no type") }
            else { recordDrop() }
            return
        }
        guard Self.knownTypes.contains(type) else {
            if let id { fail(id: id, code: .unsupported, message: "unknown type \(type)") }
            else {
                log.d("Game bridge message ignored (unknown type \(type))")
                recordDrop(reason: "unknown", type: type)
            }
            return
        }
        let payload = object["payload"] as? [String: Any] ?? [:]
        if type == "action" {
            handleAction(id: id, payload: payload)
            return
        }
        if type == "motion" {
            handleMotion(id: id, payload: payload)
            return
        }
        if type == "storage" {
            handleStorageAlias(id: id, payload: payload)
            return
        }
        if type == "ready" {
            let version = (payload["bridgeVersion"] as? NSNumber)?.intValue ?? Self.bridgeVersion
            if state == .loading {
                state = .idle
                onReady?(version)
            } else {
                onRepeatedReady?(version)
            }
            return
        }
        if type == "event" || type == "log" || type == "haptics" {
            handleNotification(type: type, id: id, payload: payload)
            return
        }
        guard let request = Self.parse(type: type, id: id, payload: payload) else {
            if let id { fail(id: id, code: .invalid, message: "malformed \(type) payload") }
            else { recordDrop() }
            return
        }
        onRequest?(request)
    }

    /// Fires from the one-shot ready timer. Only a session still `loading`
    /// closes here; anything past `ready` is unaffected.
    func readyTimeoutFired(generation: Int) {
        guard generation == self.generation, state == .loading else { return }
        state = .closed
        log.w("Game closed — ready timed out")
        onFailed?(.readyTimeout)
    }

    /// Native close button, back, skin `close`, or teardown. First call wins;
    /// teardown after a failure is a no-op, never a second callback.
    func close() {
        guard state != .closed else { return }
        state = .closed
        onClosed?()
    }

    /// Answers a request with `{id, type:"result", payload}`.
    func answer(id: String, payload: [String: Any] = [:]) {
        send(["id": id, "type": "result", "payload": payload])
    }

    /// Answers a request with `{id, type:"error", payload:{code, message}}`.
    func fail(id: String, code: GameBridgeErrorCode, message: String) {
        send(["id": id, "type": "error", "payload": ["code": code.rawValue, "message": message]])
    }

    /// Pushes a native→skin message (`init`, `lifecycle`, `viewport`,
    /// `device`, `sensor`) — no id, no reply.
    func push(type: String, payload: [String: Any]) {
        send(["type": type, "payload": payload])
    }

    /// `window.DigiaBridge.__receive(<json string literal>)`. The payload is
    /// JSON-encoded twice — once as the message, once as the string literal
    /// argument — so text values can never break out of the script.
    static func receiveScript(for message: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(
                  withJSONObject: message, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8),
              let literalData = try? JSONEncoder().encode(json),
              let literal = String(data: literalData, encoding: .utf8)
        else { return nil }
        return "window.DigiaBridge.__receive(\(literal))"
    }

    private func send(_ message: [String: Any]) {
        guard let script = Self.receiveScript(for: message) else {
            log.w("Game bridge reply dropped — payload not JSON")
            return
        }
        onSend?(script)
    }

    private func recordDrop(reason: String = "malformed", type: String? = nil) {
        if !didRecordDrop {
            didRecordDrop = true
            log.w("Game bridge message dropped (unknown, malformed, or over 64 KB)")
            onDropped?(reason, type)
        } else if log.isEnabled(.debug) {
            log.d("Game bridge message dropped (unknown, malformed, or over 64 KB)")
        }
    }

    // MARK: - Parsing

    /// Builds the typed request for a known `type`, or nil when the payload
    /// is malformed. Requests the skin cannot be answered for (no usable id)
    /// parse as nil too, so the caller drops them.
    private static func parse(type: String, id: String?, payload: [String: Any]) -> GameBridgeRequest? {
        switch type {
        case "http":
            guard let id else { return nil }
            guard let method = payload.nonBlankString("method"),
                  let path = payload.nonBlankString("path")
            else { return nil }
            if let body = payload["body"], !(body is [String: Any]) { return nil }
            return .http(id: id, method: method, path: path, body: payload["body"] as? [String: Any])
        case "sensor.start":
            guard let id,
                  let sensor = payload.nonBlankString("sensor"),
                  sensor == GameMotionSource.gyroscopeName || sensor == GameMotionSource.accelerometerName
            else { return nil }
            return .sensorStart(id: id, sensor: sensor, hz: GameMotionSource.clampedHz(number(payload["hz"])))
        case "sensor.stop":
            guard let id,
                  let sensor = payload.nonBlankString("sensor")
            else { return nil }
            return .sensorStop(id: id, sensor: sensor)
        case "storage.get":
            guard let id, let key = payload.nonBlankString("key") else { return nil }
            return .storageGet(id: id, key: key)
        case "storage.set":
            guard let id, let key = payload.nonBlankString("key"),
                  let value = payload["value"] as? String
            else { return nil }
            return .storageSet(id: id, key: key, value: value)
        case "storage.remove":
            guard let id, let key = payload.nonBlankString("key") else { return nil }
            return .storageRemove(id: id, key: key)
        default:
            return nil
        }
    }

    /// `event`, `log` and `haptics` never get a reply, even with an id.
    /// Invalid forms are ignored: an event with no name or bad props, a log
    /// with no message, or a haptics call with no style does nothing. An
    /// unknown log level is treated as debug; an unknown haptic style runs
    /// through and no-ops in the player.
    private func handleNotification(type: String, id: String?, payload: [String: Any]) {
        switch type {
        case "event":
            guard let name = payload.nonBlankString("name") else {
                log.d("Game event ignored (missing name)")
                return
            }
            guard payload["props"] == nil || payload["props"] is [String: Any] else {
                log.d("Game event ignored (bad props)")
                return
            }
            onRequest?(.event(id: id, name: name, props: payload["props"] as? [String: Any] ?? [:]))
        case "log":
            guard let message = payload["message"] as? String, !message.isEmpty else { return }
            let level = payload.nonBlankString("level") ?? "debug"
            onRequest?(.log(id: id, level: level, message: message))
        case "haptics":
            guard let style = payload.nonBlankString("style") else { return }
            onRequest?(.haptics(id: id, style: style))
        default:
            break
        }
    }

    /// The `action` intake. A `steps` payload runs through the same parser the
    /// canvas onClick uses; single ops read `payload.op` (falling back to the
    /// shipped `payload.action`) and map to the generic executor's actions.
    /// A form the SDK does not know answers `unsupported` when it carries an
    /// id (and is ignored otherwise); a known form with bad fields answers
    /// `invalid`. A request the skin cannot be answered for (no usable id) is
    /// dropped — an id-less action still runs, it just gets no reply.
    private func handleAction(id: String?, payload: [String: Any]) {
        switch Self.parseActionResult(id: id, payload: payload) {
        case .request(let request):
            onRequest?(request)
        case .malformed:
            if let id { fail(id: id, code: .invalid, message: "malformed action payload") }
            else { recordDrop() }
        case .unknown:
            if let id { fail(id: id, code: .unsupported, message: "unsupported action") }
            else { log.d("Game bridge action ignored (unsupported)") }
        }
    }

    private enum ActionParseOutcome {
        case request(GameBridgeRequest)
        case malformed
        case unknown
    }

    private static func parseActionResult(id: String?, payload: [String: Any]) -> ActionParseOutcome {
        if payload["steps"] != nil {
            guard let steps = payload["steps"] as? [[String: Any]] else { return .malformed }
            let parsed = EngageActionParser().parseReportingUnknown(["steps": steps])
            if parsed.hasUnknown { return .unknown }
            return .request(.actionSteps(id: id, actions: parsed.actions))
        }
        guard let op = payload.nonBlankString("op") ?? payload.nonBlankString("action") else {
            return .unknown
        }
        switch op {
        case "copy":
            guard let text = payload["text"] as? String else { return .malformed }
            return .request(.actionCopy(id: id, text: text))
        case "openLink", "openUrl":
            guard let raw = payload.nonBlankString("url"),
                  let url = URL(string: raw),
                  isOpenableLink(url)
            else { return .malformed }
            return .request(.actionOpenLink(id: id, url: url))
        case "deeplink":
            guard let raw = payload.nonBlankString("url"),
                  let url = URL(string: raw),
                  isOpenableLink(url)
            else { return .malformed }
            return .request(.actionOpenDeeplink(id: id, url: url))
        case "customKV":
            guard let raw = payload["payload"] as? [String: Any],
                  case .customKV(let kv) = EngageActionParser.customKV(from: raw)
            else { return .malformed }
            return .request(.actionCustomKV(id: id, payload: kv))
        case "share":
            guard let text = payload["text"] as? String else { return .malformed }
            return .request(.actionShare(id: id, text: text))
        case "close":
            return .request(.actionClose(id: id, reason: payload["reason"] as? String))
        default:
            return .unknown
        }
    }

    /// The `motion` alias for `sensor.start` / `sensor.stop`: one subscribe
    /// starts every listed sensor at the same rate, one unsubscribe stops the
    /// listed sensors (or every sensor when none are listed). An id-less
    /// motion has no reply path, so it is dropped.
    private func handleMotion(id: String?, payload: [String: Any]) {
        guard let id else {
            recordDrop()
            return
        }
        guard let op = payload.nonBlankString("op") else {
            fail(id: id, code: .invalid, message: "malformed motion payload")
            return
        }
        switch op {
        case "subscribe":
            guard let sensors = payload["sensors"] as? [String], !sensors.isEmpty,
                  sensors.allSatisfy(Self.isMotionSensor)
            else {
                fail(id: id, code: .invalid, message: "malformed motion payload")
                return
            }
            onRequest?(.motionSubscribe(
                id: id, sensors: sensors,
                hz: GameMotionSource.clampedHz(Self.number(payload["hz"]))))
        case "unsubscribe":
            let sensors = payload["sensors"] as? [String] ?? []
            guard sensors.allSatisfy(Self.isMotionSensor) else {
                fail(id: id, code: .invalid, message: "malformed motion payload")
                return
            }
            onRequest?(.motionUnsubscribe(id: id, sensors: sensors))
        default:
            fail(id: id, code: .unsupported, message: "unsupported motion op")
        }
    }

    /// The `storage` alias for `storage.get` / `storage.set` / `storage.remove`.
    /// Maps to the same requests, so the replies keep their shipped shape.
    private func handleStorageAlias(id: String?, payload: [String: Any]) {
        guard let id else {
            recordDrop()
            return
        }
        guard let op = payload.nonBlankString("op") else {
            fail(id: id, code: .invalid, message: "malformed storage payload")
            return
        }
        switch op {
        case "get":
            guard let key = payload.nonBlankString("key") else {
                fail(id: id, code: .invalid, message: "malformed storage payload")
                return
            }
            onRequest?(.storageGet(id: id, key: key))
        case "set":
            guard let key = payload.nonBlankString("key"),
                  let value = payload["value"] as? String
            else {
                fail(id: id, code: .invalid, message: "malformed storage payload")
                return
            }
            onRequest?(.storageSet(id: id, key: key, value: value))
        case "remove":
            guard let key = payload.nonBlankString("key") else {
                fail(id: id, code: .invalid, message: "malformed storage payload")
                return
            }
            onRequest?(.storageRemove(id: id, key: key))
        default:
            fail(id: id, code: .unsupported, message: "unsupported storage op")
        }
    }

    private static func isMotionSensor(_ sensor: String) -> Bool {
        sensor == GameMotionSource.gyroscopeName || sensor == GameMotionSource.accelerometerName
    }

    /// Schemes that would run code, read local data or bypass the host's link routing.
    private static let blockedLinkSchemes: Set<String> = [
        "javascript", "vbscript", "data", "blob", "file", "about",
    ]

    /// Web links need a host; app deep links (`medihub://cart`) only a safe scheme.
    private static func isOpenableLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "http" || scheme == "https" { return !(url.host ?? "").isEmpty }
        return !blockedLinkSchemes.contains(scheme)
    }

    /// A JSON number as a Double: `hz` may arrive as either. Non-numbers and
    /// non-finite values read as nil, and the caller falls back to the default.
    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        return double.isFinite ? double : nil
    }

}
