import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Wire error codes for `{id, type:"error"}` replies — the whole set. A skin
/// feature-detects by sending a request and handling `unsupported`.
enum GameBridgeError: String, Sendable, Error {
    case unsupported
    case badRequest = "bad_request"
    case network
    case timeout
    case server
    /// The session closed before the request was answered.
    case closed
}

/// One typed skin→native message the presentation handles. `log` and
/// `haptics` never get a reply, even with an id; `ready` never reaches
/// here — the bridge answers nothing for it; the first one fires the init
/// flow. `action.*` carries an optional id: answered with `result {ok:true}`
/// when present, silent otherwise.
enum GameBridgeRequest {
    case http(id: String, method: String, path: String, body: [String: Any]?)
    case log(id: String?, level: String, message: String)
    case haptics(id: String?, style: GameHapticStyle)
    case storageGet(id: String, key: String)
    case storageSet(id: String, key: String, value: String)
    case storageRemove(id: String?, key: String)
    case actionCopy(id: String?, text: String)
    case actionOpenLink(id: String?, op: String, url: URL)
    case actionOpenDeeplink(id: String?, url: URL)
    case actionShare(id: String?, text: String)
    case actionCustomKV(id: String?, payload: [String: String])
    case actionClose(id: String?, reason: String?)
    case motionSubscribe(id: String, sensors: [String], hz: Double)
    case motionUnsubscribe(id: String, sensors: [String])
    /// An `action` op with no named case, parsed by the canvas action parser
    /// as `{type: op, data: payload}` (e.g. `requestReview`). Canvas-only
    /// actions never reach here — the intake answers them as `unsupported`.
    case actionPassthrough(id: String?, op: String, action: EngageAction)
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
    /// The SDK's bridge version, sent in `init`. A skin declaring a higher
    /// version is refused by the presentation.
    nonisolated static let bridgeVersion = 2
    /// Seconds from the page commit to `ready` before the container closes quietly.
    nonisolated static let readyTimeoutSeconds = 5.0
    /// Seconds from load start to the page commit before the container closes
    /// quietly. Its own budget, so a slow engine start on a cheap phone does
    /// not eat the skin's 5 s.
    nonisolated static let loadTimeoutSeconds = 15.0
    /// Bound for one skin `http` call the game waits on (`state`, `play`,
    /// `getRewards`): `http` already answers `error timeout` at 20 s
    /// (`timeoutSeconds`), so a call still pending here means the native stack
    /// hung and will never answer. 30 s = the 20 s http timeout plus headroom
    /// for timer slop on low-end devices and a full skin busy-retry cycle, so
    /// a healthy-but-slow call is always answered first. Same value on Android
    /// (`GAME_HTTP_WATCHDOG_MS`); the stuck game closes instead of freezing.
    nonisolated static let httpWatchdogSeconds: TimeInterval = 30.0
    /// Skin messages above this many UTF-8 bytes are dropped, never parsed. Fits a
    /// full 16 KB `storage` value or `http` body plus its envelope.
    nonisolated static let maxMessageBytes = 64 * 1024

    /// How often an open game re-collects device facts so thermal, power-save
    /// and reduced-motion changes push without a viewport change (B21). Pushes
    /// fire only when the pushed subset changed, so the tick is one cheap
    /// collect. Mirrors Android's `DEVICE_FACTS_POLL_MS`.
    nonisolated static let deviceFactsPollSeconds: TimeInterval = 5.0

    enum State: Equatable {
        case loading
        case idle
        case closed
    }

    private(set) var state: State = .loading
    /// Set once per session by the first dropped message.
    private(set) var dropNoted = false

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
    var onFailed: (@MainActor (GameFailureReason) -> Void)?
    /// One parsed request per skin message the bridge accepts.
    var onRequest: (@MainActor (GameBridgeRequest) -> Void)?
    /// One full `window.DigiaBridge.__receive(...)` script per reply or push.
    /// The presentation evaluates it on the main actor.
    var onSend: (@MainActor (String) -> Void)?

    /// Message types the intake accepts by `type`. Anything else is unknown.
    private static let knownTypes: Set<String> = [
        "ready", "http", "log", "haptics",
        "motion", "storage", "action",
    ]

    /// (Re)enters `loading`. Returns a generation token so the one-shot ready
    /// timer fires only for the load that armed it.
    private var generation = 0
    /// Ids of requests still owed an answer. On close each gets error
    /// `closed`, so a skin awaiting a reply never hangs (MSG-2).
    private var pendingIds = Set<String>()

    func beginLoading() -> Int {
        state = .loading
        generation += 1
        return generation
    }

    /// Invalidates the armed ready timer (the app left the foreground).
    func cancelReadyTimer() {
        generation += 1
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
            // Without an id there is no type to report: an unroutable drop.
            if let id { fail(id: id, code: .badRequest, message: "message has no type") }
            else { recordDrop(reason: "unknown") }
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
        // Notifications and `ready` are never answered, so never owed one.
        if let id, !["ready", "log", "haptics"].contains(type) { pendingIds.insert(id) }
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
            handleStorage(id: id, payload: payload)
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
            // No reply is ever sent for `ready`, even when it carries an id.
            return
        }
        if type == "log" || type == "haptics" {
            handleNotification(type: type, id: id, payload: payload)
            return
        }
        guard let request = Self.parse(type: type, id: id, payload: payload) else {
            if let id { fail(id: id, code: .badRequest, message: "malformed \(type) payload") }
            // An http call with no id is never run and is not a drop (B17), as on Android.
            else if type != "http" { recordDrop(reason: "unknown", type: type) }
            return
        }
        onRequest?(request)
    }

    /// Fires from the one-shot ready timer. Only a session still `loading`
    /// closes here; anything past `ready` is unaffected.
    func readyTimeoutFired(generation: Int) {
        timeoutFired(generation: generation, failure: .readyTimeout)
    }

    /// Fires from the one-shot load timer: the page never committed.
    func loadTimeoutFired(generation: Int) {
        timeoutFired(generation: generation, failure: .loadTimeout)
    }

    private func timeoutFired(generation: Int, failure: GameFailureReason) {
        guard generation == self.generation, state == .loading else { return }
        failPendingAsClosed()
        state = .closed
        log.w("Game closed — \(failure.wireValue)")
        onFailed?(failure)
    }

    /// Native close button, back, skin `close`, or teardown. First call wins;
    /// teardown after a failure is a no-op, never a second callback.
    func close() {
        guard state != .closed else { return }
        failPendingAsClosed()
        state = .closed
        onClosed?()
    }

    /// Answers a request with `{id, type:"result", payload}`. After close the
    /// request already got error `closed`, so a late answer is dropped.
    func answer(id: String, payload: [String: Any] = [:]) {
        pendingIds.remove(id)
        guard state != .closed else { return }
        send(["id": id, "type": "result", "payload": payload])
    }

    /// Answers a request with `{id, type:"error", payload:{code, message}}`.
    func fail(id: String, code: GameBridgeError, message: String) {
        pendingIds.remove(id)
        guard state != .closed else { return }
        send(["id": id, "type": "error", "payload": ["code": code.rawValue, "message": message]])
    }

    /// Answers every request still in flight with error `closed`.
    private func failPendingAsClosed() {
        let ids = pendingIds.sorted()
        pendingIds.removeAll()
        for id in ids {
            send(["id": id, "type": "error",
                  "payload": ["code": GameBridgeError.closed.rawValue, "message": "game closed"]])
        }
    }

    /// Pushes a native→skin message (`init`, `lifecycle`, `viewport`,
    /// `device`, `motionSample`) — no id, no reply.
    func push(type: String, payload: [String: Any]) {
        send(["type": type, "payload": payload])
    }

    /// `window.DigiaBridge.__receive(<json string literal>)`. The payload is
    /// JSON-encoded twice — once as the message, once as the string literal
    /// argument — so text values can never break out of the script.
    static func receiveScript(for message: [String: Any]) -> String? {
        stringLiteral(for: message).map { "window.DigiaBridge.__receive(\($0))" }
    }

    /// `message` as JSON, then as a JS string literal holding that JSON.
    static func stringLiteral(for message: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(
                  withJSONObject: message, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8),
              let literalData = try? JSONEncoder().encode(json),
              let literal = String(data: literalData, encoding: .utf8)
        else { return nil }
        return literal
    }

    private func send(_ message: [String: Any]) {
        guard let script = Self.receiveScript(for: message) else {
            log.w("Game bridge reply dropped — payload not JSON")
            return
        }
        onSend?(script)
    }

    private func recordDrop(reason: String = "malformed", type: String? = nil) {
        if !dropNoted {
            dropNoted = true
            log.w("Game bridge message dropped (unknown, malformed, or over 64 KB)")
            onDropped?(reason, type)
        } else if log.isEnabled(.debug) {
            log.d("Game bridge message dropped (unknown, malformed, or over 64 KB)")
        }
    }

    // MARK: - Parsing

    /// Builds the typed request for a known `type`, or nil when the payload
    /// is malformed. Requests the skin cannot be answered for (no usable id)
    /// parse as nil too, so the caller drops them. `http` forwards the
    /// method and path verbatim — even blank — so the presenter rejects and
    /// health-reports them exactly like Android's session, instead of the
    /// intake swallowing the health leg.
    private static func parse(type: String, id: String?, payload: [String: Any]) -> GameBridgeRequest? {
        switch type {
        case "http":
            guard let id else { return nil }
            if let body = payload["body"], !(body is [String: Any]) { return nil }
            return .http(
                id: id, method: payload["method"] as? String ?? "",
                path: payload["path"] as? String ?? "",
                body: payload["body"] as? [String: Any])
        default:
            return nil
        }
    }

    /// `log` and `haptics` never get a reply, even with an id. Invalid
    /// forms are ignored: a log with no message or a haptics call with no
    /// style does nothing. An unknown log level is treated as debug; an
    /// unknown haptic style is a session-level no-op — the player is never
    /// invoked, so a regression that vibrates anyway fails the shared
    /// case-table run.
    private func handleNotification(type: String, id: String?, payload: [String: Any]) {
        switch type {
        case "log":
            guard let message = payload["message"] as? String, !message.isEmpty else { return }
            onRequest?(.log(
                id: id, level: Self.validatedLogLevel(payload.nonBlankString("level")),
                message: message))
        case "haptics":
            guard let raw = payload.nonBlankString("style"),
                  let style = GameHapticStyle(rawValue: raw)
            else { return }
            onRequest?(.haptics(id: id, style: style))
        default:
            break
        }
    }

    /// A skin `log` level the bridge accepts; anything else is `debug`, like
    /// Android — never a reject, never a pass-through the logger maps to error.
    private static func validatedLogLevel(_ raw: String?) -> String {
        switch raw {
        case "debug", "info", "warn", "error": return raw!
        default: return "debug"
        }
    }

    /// The `action` intake: `{op, ...}` → `{ok:true}`. Named ops map to the
    /// generic executor's actions; any other op goes through the canvas action
    /// parser as `{type: op, data: payload}`, so a campaign action the SDK
    /// already runs reaches skins with no bridge change. A missing op or a
    /// named op with bad fields answers `bad_request`; an op the SDK cannot
    /// run answers `unsupported` (both drop with the health event without an id).
    /// A request the skin cannot be answered for (no usable id) is dropped —
    /// an id-less action still runs, it just gets no reply.
    private func handleAction(id: String?, payload: [String: Any]) {
        switch Self.parseActionResult(id: id, payload: payload) {
        case .request(let request):
            onRequest?(request)
        case .malformed:
            if let id { fail(id: id, code: .badRequest, message: "malformed action payload") }
            else { recordDrop(reason: "unknown", type: "action") }
        case .unknown:
            if let id { fail(id: id, code: .unsupported, message: "unsupported action") }
            else { recordDrop(reason: "unknown", type: "action") }
        }
    }

    private enum ActionParseOutcome {
        case request(GameBridgeRequest)
        case malformed
        case unknown
    }

    private static func parseActionResult(id: String?, payload: [String: Any]) -> ActionParseOutcome {
        guard let op = payload.nonBlankString("op") else { return .malformed }
        switch op {
        case "copy":
            guard let text = payload.nonBlankString("text") else { return .malformed }
            return .request(.actionCopy(id: id, text: text))
        case "openLink", "openUrl":
            guard let raw = payload.nonBlankString("url"),
                  let url = URL(string: raw),
                  GameLinkPolicy.isOpenableLink(url)
            else { return .malformed }
            return .request(.actionOpenLink(id: id, op: op, url: url))
        case "deeplink":
            guard let raw = payload.nonBlankString("url"),
                  let url = URL(string: raw),
                  GameLinkPolicy.isOpenableLink(url)
            else { return .malformed }
            return .request(.actionOpenDeeplink(id: id, url: url))
        case "customKV":
            guard let raw = payload["payload"] as? [String: Any],
                  case .customKV(let kv) = EngageActionParser.customKV(from: raw)
            else { return .malformed }
            return .request(.actionCustomKV(id: id, payload: kv))
        case "share":
            guard let text = payload.nonBlankString("text") else { return .malformed }
            return .request(.actionShare(id: id, text: text))
        case "close":
            return .request(.actionClose(id: id, reason: payload["reason"] as? String))
        default:
            guard let action = passthroughAction(op: op, payload: payload) else { return .unknown }
            return .request(.actionPassthrough(id: id, op: op, action: action))
        }
    }

    /// One canvas action for an op the bridge has no case for, or nil. Actions
    /// that only mean something on a canvas stage (dismiss, story paging,
    /// opening a game) stay out.
    private static func passthroughAction(op: String, payload: [String: Any]) -> EngageAction? {
        let parsed = EngageActionParser().parseReportingUnknown(
            ["steps": [["type": op, "data": payload]]])
        guard !parsed.hasUnknown, parsed.actions.count == 1, let action = parsed.actions.first else {
            return nil
        }
        switch action {
        case .dismiss, .next, .previous, .openGame, .showStory: return nil
        default: return action
        }
    }

    /// `motion`: one subscribe starts every listed sensor at the same rate, one
    /// unsubscribe stops the listed sensors. A missing op, a missing or empty
    /// sensor list, or an unknown sensor answers `bad_request`; an unknown op
    /// `unsupported`. An id-less motion has no reply path, so it drops with
    /// the health event.
    private func handleMotion(id: String?, payload: [String: Any]) {
        guard let id else {
            recordDrop(reason: "unknown", type: "motion")
            return
        }
        guard let op = payload.nonBlankString("op") else {
            fail(id: id, code: .badRequest, message: "malformed motion payload")
            return
        }
        switch op {
        case "subscribe":
            guard let sensors = payload["sensors"] as? [String], !sensors.isEmpty,
                  sensors.allSatisfy(Self.isMotionSensor)
            else {
                fail(id: id, code: .badRequest, message: "malformed motion payload")
                return
            }
            onRequest?(.motionSubscribe(
                id: id, sensors: sensors,
                hz: GameMotionSource.clampedHz(Self.number(payload["hz"]))))
        case "unsubscribe":
            guard let sensors = payload["sensors"] as? [String], !sensors.isEmpty,
                  sensors.allSatisfy(Self.isMotionSensor)
            else {
                fail(id: id, code: .badRequest, message: "malformed motion payload")
                return
            }
            onRequest?(.motionUnsubscribe(id: id, sensors: sensors))
        default:
            fail(id: id, code: .unsupported, message: "unsupported motion op")
        }
    }

    /// `storage`: the per-skin key-value store, `{op: get|set|remove, key,
    /// value?}`. An id-less `remove` still runs, like Android — there is just
    /// no reply path, so nothing is answered. Every id-less reject drops with
    /// the health event.
    private func handleStorage(id: String?, payload: [String: Any]) {
        guard let op = payload.nonBlankString("op") else {
            if let id { fail(id: id, code: .badRequest, message: "malformed storage payload") }
            else { recordDrop(reason: "unknown", type: "storage") }
            return
        }
        switch op {
        case "get":
            guard let id else {
                recordDrop(reason: "unknown", type: "storage")
                return
            }
            guard let key = payload.nonBlankString("key") else {
                fail(id: id, code: .badRequest, message: "malformed storage payload")
                return
            }
            onRequest?(.storageGet(id: id, key: key))
        case "set":
            guard let id else {
                recordDrop(reason: "unknown", type: "storage")
                return
            }
            guard let key = payload.nonBlankString("key"),
                  let value = payload["value"] as? String
            else {
                fail(id: id, code: .badRequest, message: "malformed storage payload")
                return
            }
            onRequest?(.storageSet(id: id, key: key, value: value))
        case "remove":
            guard let key = payload.nonBlankString("key") else {
                if let id { fail(id: id, code: .badRequest, message: "malformed storage payload") }
                else { recordDrop(reason: "unknown", type: "storage") }
                return
            }
            onRequest?(.storageRemove(id: id, key: key))
        default:
            if let id { fail(id: id, code: .unsupported, message: "unsupported storage op") }
            else { recordDrop(reason: "unknown", type: "storage") }
        }
    }

    private static func isMotionSensor(_ sensor: String) -> Bool {
        sensor == GameMotionSource.gyroscopeName || sensor == GameMotionSource.accelerometerName
    }

    /// A JSON number as a Double: `hz` may arrive as either. Non-numbers and
    /// non-finite values read as nil, and the caller falls back to the default.
    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        return double.isFinite ? double : nil
    }
}
