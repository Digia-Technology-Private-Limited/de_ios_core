import Foundation
import Testing

@testable import DigiaEngage

/// Runs every row of the shared bridge table
/// (`testkit/contracts/game-bridge-cases.json`, one case per hardening-spec
/// row B1–B26) through a fresh `GameBridge`: the input message in, the reply
/// or silence plus the pushes and the `game_http_failed` health event out.
/// A row fails here when the intake's reply, push or health leg drifts from
/// the contract — Android loads the same file through `GameBridgeCasesTest`.
///
/// The table lives outside this repo (it is shared workspace contract, not SDK
/// source), so the test finds it relative to this file and returns early where
/// the workspace layout is absent. That early return is load-bearing: it keeps
/// this repo's own CI green while the workspace runs the table.
///
/// What each leg pins, honestly: `GameBridge.receive` is the real intake, so
/// every reply, no-reply, push-order and drop-reason assertion names a
/// production line in it. The host side (init assembly, pause-on-close,
/// resume-on-ready, CTA and funnel emissions, health-event delivery) is
/// mirrored by the harness exactly as the row's `notes` describe — those
/// mirrors pin the contract shape, not the host trigger. The decisions the
/// host feeds on are pinned where they are pure and reachable: the storage
/// backend is the real `GameSkinStorage` on a throwaway suite, the log-level
/// and haptic-style filters are the real intake mapping, the HTTP reject and
/// failure legs run the real `GameHttpBridge` `rejectedCall` / `failedCall`
/// mapping production uses — so the table's `health` expectations pin the
/// production `game_http_failed` legs — and the device change gate is the
/// real `GamePresentation.devicePushChanged`.
@Suite("Game bridge cases", .tags(.unit, .game))
@MainActor
struct GameBridgeCasesTests {
    @Test("every shared bridge case behaves as the table says")
    func everyCase() throws {
        guard let tableURL = tableURL() else {
            // Shared bridge table absent (not a de_workspace checkout): the
            // workspace runs this; the repo's own CI skips it, like Android.
            return
        }
        let table = try JSONSerialization.jsonObject(with: Data(contentsOf: tableURL)) as! [String: Any]
        let initFixture = table["init"] as! [String: Any]
        let cases = table["cases"] as! [[String: Any]]
        for row in cases {
            let id = row["id"] as! String
            do {
                try runCase(initFixture: initFixture, row: row)
            } catch {
                Issue.record("case \(id): \(error)")
            }
        }
    }

    /// The shared table, resolved from this file's workspace path: this file
    /// lives at `<workspace>/ios/core/Tests/DigiaEngageTests/Gamification/`,
    /// five levels below the workspace root.
    private func tableURL() -> URL? {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        let candidate = url.appendingPathComponent("testkit/contracts/game-bridge-cases.json")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    // MARK: - Harness

    /// One message the harness "sent" to the skin.
    private struct Push: Equatable {
        let type: String
        let payload: [String: Any]

        static func == (left: Push, right: Push) -> Bool {
            guard left.type == right.type else { return false }
            return NSDictionary(dictionary: left.payload).isEqual(to: right.payload)
        }
    }

    /// One `game_http_failed` the session mapping reported: the reply code
    /// plus the health fields, through the same
    /// `GameHttpBridge.rejectedCall` / `failedCall` mapping production uses.
    private struct HealthEvent: Equatable {
        let event: String
        let method: String
        let path: String
        let code: String
        let status: Int?
    }

    /// The host, in miniature: a real intake with captured callbacks.
    @MainActor
    private final class Harness {
        let bridge = GameBridge()
        var requests: [GameBridgeRequest] = []
        var scripts: [String] = []
        var drops: [(reason: String, type: String?)] = []
        var readyVersions: [Int] = []
        var closed = false

        // Sinks the host owns.
        var storage: GameSkinStorage!
        var haptics: [String] = []
        var events: [(name: String, props: [String: Any])] = []
        var logs: [(level: String, message: String)] = []
        var httpCalls: [(method: String, path: String, body: [String: Any]?)] = []
        var httpOutcome = "raw"
        var healthEvents: [HealthEvent] = []
        var pushes: [Push] = []
        var lastDevicePush: [String: Any]?
        var initMessage: [String: Any] = [:]
        var settingUp = true

        init(rowId: String) {
            let defaults = UserDefaults(suiteName: "test-game-cases-\(rowId)-\(UUID().uuidString)")!
            storage = GameSkinStorage(
                defaults: defaults,
                namespace: GameSkinStorage.namespace(
                    projectId: "proj", skinId: "skin", identity: "user-\(rowId)"))
            bridge.onRequest = { [weak self] in self?.requests.append($0) }
            bridge.onSend = { [weak self] in self?.scripts.append($0) }
            bridge.onDropped = { [weak self] reason, type in self?.drops.append((reason, type)) }
            bridge.onReady = { [weak self] in self?.didBecomeReady(version: $0) }
            bridge.onRepeatedReady = { [weak self] _ in self?.didRepeatReady() }
            bridge.onClosed = { [weak self] in self?.closed = true }
        }

        private func didBecomeReady(version: Int) {
            readyVersions.append(version)
            guard !settingUp else { return }
            pushes.append(Push(type: "init", payload: initMessage))
        }

        private func didRepeatReady() {
            guard !settingUp else { return }
            // A skin re-announcing itself on an open game gets the current
            // state again: init, then resume — the host mirror of the B2 fix.
            pushes.append(Push(type: "init", payload: initMessage))
            pushes.append(Push(type: "lifecycle", payload: ["state": "resumed"]))
        }

        func handleRequests() {
            for request in requests {
                switch request {
                case .http(let id, let method, let path, let body):
                    handleHttp(id: id, method: method, path: path, body: body)
                case .event(_, let name, let props):
                    events.append((name, props))
                case .log(_, let level, let message):
                    logs.append((level, message))
                case .haptics(_, let style):
                    haptics.append(style.rawValue)
                case .storageGet(let id, let key):
                    handleStorageGet(id: id, key: key)
                case .storageSet(let id, let key, let value):
                    handleStorageSet(id: id, key: key, value: value)
                case .storageRemove(let id, let key):
                    guard GameSkinStorage.isValidKey(key) else {
                        if let id { fail(id: id, code: .badRequest) }
                        return
                    }
                    storage.remove(key)
                    if let id { answer(id: id) }
                    else { failOnHarness("storage.remove without id must not answer") }
                case .actionClose(let id, _):
                    // The host mirror: pause goes out first, then the host
                    // closes — the B3/B24 session leg.
                    pushes.append(Push(type: "lifecycle", payload: ["state": "paused"]))
                    if let id { answer(id: id, payload: ["ok": true]) }
                    bridge.close()
                default:
                    break
                }
            }
            requests.removeAll()
        }

        private func handleHttp(id: String, method: String, path: String, body: [String: Any]?) {
            // The session forwards the method verbatim and answers what the
            // transport says — here a canned outcome, like Android's fake
            // http call. The exact GET/POST gate one layer down is pinned by
            // GameSkinHttpTests, not by this table. A missing method or path
            // never runs: the harness rejects it through the same
            // `rejectedCall` mapping the presenter uses, and every transport
            // failure reports through the same `failedCall` mapping — so
            // B14–B16 pin the production health legs.
            func reject(code: GameBridgeErrorCode) {
                fail(id: id, code: code)
                let failed = GameHttpBridge.rejectedCall(method: method, path: path, code: code)
                healthEvents.append(HealthEvent(
                    event: "game_http_failed", method: failed.method, path: failed.path,
                    code: failed.code.rawValue, status: failed.status))
            }
            func failOutcome(_ failure: GameHttpBridge.Failure) {
                fail(id: id, code: failure.code)
                let failed = GameHttpBridge.failedCall(method: method, path: path, failure: failure)
                healthEvents.append(HealthEvent(
                    event: "game_http_failed", method: failed.method, path: failed.path,
                    code: failed.code.rawValue, status: failed.status))
            }
            guard !method.isEmpty, !path.isEmpty else {
                reject(code: .badRequest)
                return
            }
            httpCalls.append((method, path, body))
            switch httpOutcome {
            case "timeout":
                failOutcome(GameHttpBridge.Failure(code: .timeout, status: nil))
            case "network":
                failOutcome(GameHttpBridge.Failure(code: .network, status: nil))
            default:
                answer(id: id, payload: ["status": 200, "body": ["isSuccess": true]])
            }
        }

        private func failOnHarness(_ message: String) {
            Issue.record("harness: \(message)")
        }

        private func handleStorageGet(id: String, key: String) {
            guard GameSkinStorage.isValidKey(key) else {
                fail(id: id, code: .badRequest)
                return
            }
            if let value = storage.get(key) {
                answer(id: id, payload: ["value": value])
            } else {
                answer(id: id, payload: ["value": NSNull()])
            }
        }

        private func handleStorageSet(id: String, key: String, value: String) {
            if storage.set(key, value: value) != nil {
                fail(id: id, code: .badRequest)
            } else {
                answer(id: id)
            }
        }

        func answer(id: String, payload: [String: Any] = [:]) {
            bridge.answer(id: id, payload: payload)
        }

        func fail(id: String, code: GameBridgeErrorCode) {
            bridge.fail(id: id, code: code, message: code.rawValue)
        }

        func applyDeviceFacts(_ facts: [String: Any]) {
            // First application sets the pushed baseline; repeats must push
            // nothing; the last one is asserted against expect.
            var device = GameDeviceInfo(
                osVersion: "18.0", sdkVersion: "test", model: "test",
                locale: "en", timezone: "UTC",
                hapticsAllowed: true, soundAllowed: true, reducedMotion: false,
                tier: "full", ramMb: 8192, cores: 6,
                thermal: "nominal", lowPower: false, sensors: [])
            if let tier = facts["tier"] as? String { device.tier = tier }
            if let thermal = facts["thermal"] as? String { device.thermal = thermal }
            if let lowPower = facts["lowPower"] as? Bool { device.lowPower = lowPower }
            if let reducedMotion = facts["reducedMotion"] as? Bool { device.reducedMotion = reducedMotion }
            if let soundAllowed = facts["soundAllowed"] as? Bool { device.soundAllowed = soundAllowed }
            let push = device.pushPayload
            if lastDevicePush == nil {
                lastDevicePush = push
                return
            }
            if GamePresentation.devicePushChanged(push, from: lastDevicePush) {
                lastDevicePush = push
                pushes.append(Push(type: "device", payload: push))
            }
        }
    }

    // MARK: - Runner

    private func runCase(initFixture: [String: Any], row: [String: Any]) throws {
        let id = row["id"] as! String
        let harness = Harness(rowId: id)
        harness.initMessage = initMessage(fixture: initFixture)

        let setup = (row["setup"] as? [String]) ?? []
        if setup.contains("open") {
            harness.bridge.receive(json(["type": "ready"]))
            harness.handleRequests()
        }
        harness.settingUp = false
        harness.scripts.removeAll()
        harness.pushes.removeAll()
        harness.drops.removeAll()
        harness.healthEvents.removeAll()

        if let applications = row["hostDevice"] as? [[String: Any]] {
            for (index, facts) in applications.enumerated() {
                harness.pushes.removeAll()
                harness.healthEvents.removeAll()
                harness.applyDeviceFacts(facts)
                if index > 0 && index < applications.count - 1 {
                    try check(id: id, pitches: "no push on unchanged facts", harness.pushes.isEmpty)
                }
            }
        }
        if let message = row["message"] as? String {
            if let outcome = (row["http"] as? [String: Any])?["outcome"] as? String {
                harness.httpOutcome = outcome
            }
            harness.bridge.receive(message)
            harness.handleRequests()
        }

        let expect = row["expect"] as! [String: Any]
        try assertReply(id: id, row: row, expect: expect, harness: harness)
        try assertPushes(id: id, expect: expect, harness: harness)
        try assertHealth(id: id, expect: expect, harness: harness)
        if let httpCalls = expect["httpCalls"] as? Int {
            try check(id: id, pitches: "http calls", harness.httpCalls.count == httpCalls)
        }
        if let call = expect["httpCall"] as? [String: Any] {
            let last = try require(id: id, pitches: "http call", harness.httpCalls.last)
            try check(id: id, pitches: "http method", last.method == (call["method"] as? String))
            try check(id: id, pitches: "http path", last.path == (call["path"] as? String))
        }
        if let haptics = expect["haptics"] as? [String] {
            try check(id: id, pitches: "haptics", harness.haptics == haptics)
        }
        if expect.keys.contains("event") {
            if expect["event"] is NSNull {
                try check(id: id, pitches: "no skin event", harness.events.isEmpty)
            } else if let want = expect["event"] as? [String: Any] {
                try check(id: id, pitches: "skin events", harness.events.count == 1)
                let got = try require(id: id, pitches: "skin event", harness.events.first)
                try check(id: id, pitches: "event name", got.name == (want["name"] as? String))
                if let props = want["props"] as? [String: Any] {
                    try check(
                        id: id, pitches: "event props",
                        jsonSubset(props, got.props))
                }
            }
        }
        if let log = expect["log"] as? [Any] {
            // expect.log is [level, message].
            try check(id: id, pitches: "logs", harness.logs.count == 1)
            let got = try require(id: id, pitches: "log", harness.logs.first)
            try check(id: id, pitches: "log level", got.level == (log[0] as? String))
            try check(id: id, pitches: "log message", got.message == (log[1] as? String))
        }
    }

    // MARK: - Init fixture

    /// The `init` the host sends after `ready`, built from this file's
    /// fixture through the real `GameInitPayload` — the B19/B20 shape leg.
    private func initMessage(fixture: [String: Any]) -> [String: Any] {
        var values: [String: JSONValue] = [:]
        for (key, raw) in (fixture["values"] as? [String: Any]) ?? [:] {
            if let value = GamificationJSON.value(raw) { values[key] = value }
        }
        let theme = fixture["theme"] as? [String: Any] ?? [:]
        let fonts = (theme["fonts"] as? [[String: Any]] ?? []).compactMap { font -> [String: String]? in
            guard let family = font["family"] as? String,
                  let url = font["url"] as? String
            else { return nil }
            return ["family": family, "url": url]
        }
        let viewport = fixture["viewport"] as? [String: Any] ?? [:]
        let safeArea = (viewport["safeArea"] as? [String: Any])
        return GameInitPayload(
            chanceId: fixture["chanceId"] as? String ?? "",
            campaignId: fixture["campaignId"] as? String ?? "",
            campaignKey: fixture["campaignKey"] as? String ?? "",
            skinId: fixture["skinId"] as? String ?? "",
            skinVersion: fixture["skinVersion"] as? Int ?? 0,
            values: values,
            slots: [],
            viewportWidth: viewport["width"] as? Double ?? 0,
            viewportHeight: viewport["height"] as? Double ?? 0,
            safeArea: GameSafeArea(
                top: (safeArea?["top"] as? Double) ?? 0,
                right: (safeArea?["right"] as? Double) ?? 0,
                bottom: (safeArea?["bottom"] as? Double) ?? 0,
                left: (safeArea?["left"] as? Double) ?? 0),
            colorScheme: "light",
            fontFamily: theme["fontFamily"] as? String,
            themeFonts: fonts,
            device: GameDeviceInfo(
                osVersion: "18.0", sdkVersion: "test", model: "test",
                locale: "en", timezone: "UTC",
                hapticsAllowed: true, soundAllowed: true, reducedMotion: false,
                tier: "full", ramMb: 8192, cores: 6,
                thermal: "nominal", lowPower: false, sensors: [])
        ).message()
    }

    // MARK: - Assertions

    private func replies(_ harness: Harness) throws -> [[String: Any]] {
        try harness.scripts.map { script in
            let prefix = "window.DigiaBridge.__receive("
            guard script.hasPrefix(prefix), script.hasSuffix(")") else {
                throw CaseError("bad script: \(script)")
            }
            let start = script.index(script.startIndex, offsetBy: prefix.count)
            let literal = String(script[start...].dropLast())
            let encoded = try require(pitches: "script literal", literal.data(using: .utf8))
            let json = try require(pitches: "script json", try? JSONDecoder().decode(String.self, from: encoded))
            let data = try require(pitches: "message data", json.data(using: .utf8))
            return try require(
                pitches: "message object",
                JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    private func assertReply(id: String, row: [String: Any], expect: [String: Any], harness: Harness) throws {
        let messages = try replies(harness).filter { $0["id"] != nil }
        guard let want = expect["reply"] as? [String: Any] else {
            try check(id: id, pitches: "no reply", messages.isEmpty)
            return
        }
        try check(id: id, pitches: "one reply", messages.count == 1)
        let got = try require(id: id, pitches: "reply", messages.first)
        try check(id: id, pitches: "reply type", (got["type"] as? String) == (want["type"] as? String))
        if let code = want["code"] as? String {
            let payload = try require(id: id, pitches: "reply payload", got["payload"] as? [String: Any])
            try check(id: id, pitches: "reply code", (payload["code"] as? String) == code)
        }
    }

    private func assertPushes(id: String, expect: [String: Any], harness: Harness) throws {
        let wants = (expect["pushes"] as? [[String: Any]]) ?? []
        try check(id: id, pitches: "push count", harness.pushes.count == wants.count)
        for (want, got) in zip(wants, harness.pushes) {
            try check(
                id: id, pitches: "push \(want["type"] as? String ?? "?") type",
                (want["type"] as? String) == got.type)
            if let payload = want["payload"] as? [String: Any] {
                try check(
                    id: id, pitches: "push \(got.type) payload",
                    jsonSubset(payload, got.payload))
            }
        }
    }

    /// Mirrors Android's `assertHealth`: no `health` key means no health
    /// event; otherwise exactly one `game_http_failed` whose present keys
    /// match. Absent keys are not asserted (the table pins `event`/`method`/
    /// `path`/`code`; `status` rides along unasserted).
    private func assertHealth(id: String, expect: [String: Any], harness: Harness) throws {
        guard let want = expect["health"] as? [String: Any] else {
            try check(id: id, pitches: "no health", harness.healthEvents.isEmpty)
            return
        }
        try check(id: id, pitches: "one health event", harness.healthEvents.count == 1)
        let got = try require(id: id, pitches: "health event", harness.healthEvents.first)
        try check(id: id, pitches: "health event", got.event == (want["event"] as? String))
        if let method = want["method"] as? String {
            try check(id: id, pitches: "health method", got.method == method)
        }
        if let path = want["path"] as? String {
            try check(id: id, pitches: "health path", got.path == path)
        }
        if let code = want["code"] as? String {
            try check(id: id, pitches: "health code", got.code == code)
        }
        if let status = want["status"] as? Int {
            try check(id: id, pitches: "health status", got.status == status)
        }
    }

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// Every key of `subset` equals in `object`, recursing into dictionaries
    /// and element-wise into arrays. JSON booleans decode as `NSNumber` while
    /// Swift builds `Bool`, so scalars compare through `NSNumber` first —
    /// otherwise every `false` in a push payload would mismatch.
    private func jsonSubset(_ subset: [String: Any], _ object: [String: Any]) -> Bool {
        for (key, value) in subset {
            guard let other = object[key], jsonEqual(value, other) else { return false }
        }
        return true
    }

    private func jsonEqual(_ left: Any, _ right: Any) -> Bool {
        if let sub = left as? [String: Any], let obj = right as? [String: Any] {
            return jsonSubset(sub, obj)
        }
        if let sub = left as? [Any], let obj = right as? [Any] {
            guard sub.count == obj.count else { return false }
            return zip(sub, obj).allSatisfy(jsonEqual)
        }
        if let sub = left as? NSNumber, let obj = right as? NSNumber {
            return sub == obj
        }
        if let sub = left as? String, let obj = right as? String {
            return sub == obj
        }
        return "\(left)" == "\(right)"
    }

    private struct CaseError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func require<T>(id: String = "", pitches: String, _ value: T?) throws -> T {
        guard let value else { throw CaseError("case \(id): missing \(pitches)") }
        return value
    }

    private func check(id: String, pitches: String, _ condition: Bool) throws {
        if !condition { throw CaseError("case \(id): \(pitches)") }
    }
}
