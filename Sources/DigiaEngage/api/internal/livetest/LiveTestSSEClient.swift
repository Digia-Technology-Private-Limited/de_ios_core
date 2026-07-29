import Foundation

/// One parsed `campaign_test`/`connected`/`error` SSE event from the live-test
/// connect stream. Heartbeat comments (`: ping`) are dropped before dispatch —
/// see `runConnection`.
enum LiveTestSseEvent {
    case connected(sdkConnectionId: String, deviceId: String)
    case campaignTest(LiveTestInvocation)
    case streamError(String)
}

/// Low-level transport for `POST /api/v1/engage/sdk/live/connect`, built on
/// `URLSession.bytes(for:)` (`AsyncBytesSequence`, available since iOS 15,
/// this package's deployment target) — no third-party SSE package exists or is
/// needed; `AsyncLineSequence` already does the line-splitting, so the only
/// custom parsing here is grouping lines into `event:`/`data:` blocks on the
/// blank-line boundary.
///
/// There is no built-in reconnect — `scheduleReconnect` implements the same
/// exponential-backoff-with-jitter loop used by this feature's sibling ports.
/// Every (re)connect attempt reuses the single `session` built once in the
/// initializer rather than creating a fresh `URLSession` per attempt — a fresh
/// never-closed session per attempt, in a loop that can retry every few
/// seconds indefinitely, would leak the underlying connection.
///
/// `stop()` cancels the in-flight `Task` (`connectTask`); Foundation's async
/// `bytes(for:)` ties the underlying `URLSessionTask`'s lifetime to that Task's
/// cancellation, so cancelling it is sufficient to release the connection —
/// there's no separate task handle to close, unlike Dio/OkHttp on the sibling
/// ports.
@MainActor
final class LiveTestSSEClient {
    private let config: () -> DigiaConfig
    private let deviceId: () -> String
    private let onEvent: (LiveTestSseEvent) -> Void
    private let onConnectionStateChanged: (LiveTestConnectionState) -> Void
    private let session: URLSession

    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var stopped = true

    var isRunning: Bool { !stopped }

    init(
        config: @escaping () -> DigiaConfig,
        deviceId: @escaping () -> String,
        onEvent: @escaping (LiveTestSseEvent) -> Void,
        onConnectionStateChanged: @escaping (LiveTestConnectionState) -> Void,
        session: URLSession? = nil
    ) {
        self.config = config
        self.deviceId = deviceId
        self.onEvent = onEvent
        self.onConnectionStateChanged = onConnectionStateChanged
        if let session {
            self.session = session
        } else {
            let sessionConfig = URLSessionConfiguration.default
            // > the backend's 15s heartbeat interval (with margin), so a
            // healthy-but-quiet-between-heartbeats stream never trips a false
            // disconnect; matches the backend's own 45s presence-lease TTL as
            // the outer bound for "this connection is actually dead."
            sessionConfig.timeoutIntervalForRequest = 45
            self.session = URLSession(configuration: sessionConfig)
        }
    }

    /// Idempotent — a second call while already running is a no-op.
    func start() {
        guard stopped else { return }
        stopped = false
        reconnectAttempt = 0
        connect()
    }

    /// Idempotent. Cancels any in-flight connection/reconnect task and marks
    /// the client as intentionally stopped, so a subsequent stream error/close
    /// doesn't schedule a reconnect.
    func stop() {
        guard !stopped else { return }
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        onConnectionStateChanged(.disconnected)
    }

    private func connect() {
        guard !stopped else { return }
        onConnectionStateChanged(.connecting)
        connectTask = Task { [weak self] in
            await self?.runConnection()
        }
    }

    private func runConnection() async {
        guard !stopped else { return }
        let cfg = config()
        guard let url = URL(string: DigiaEndpoints.liveTestConnect) else {
            handleDisconnect("invalid live test URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cfg.apiKey, forHTTPHeaderField: "X-Digia-Project-Id")
        request.setValue(deviceId(), forHTTPHeaderField: "X-Digia-Device-Id")
        // Always 'debug' — this client only ever runs in a debug build.
        request.setValue("debug", forHTTPHeaderField: "X-Digia-Environment")
        request.setValue("ios", forHTTPHeaderField: "X-Digia-Platform")
        request.setValue(DigiaSdkVersion.value, forHTTPHeaderField: "X-Digia-Version")
        request.setValue("Apple", forHTTPHeaderField: "X-Digia-Device-Make")
        request.setValue(Self.deviceModel(), forHTTPHeaderField: "X-Digia-Device-Model")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                handleDisconnect("unexpected status: \(status)")
                return
            }

            var eventName: String?
            var dataLines: [String] = []
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                if line.isEmpty {
                    if eventName != nil || !dataLines.isEmpty {
                        dispatch(event: eventName, data: dataLines.joined(separator: "\n"))
                    }
                    eventName = nil
                    dataLines = []
                    continue
                }
                if line.hasPrefix(":") { continue } // heartbeat comment
                if line.hasPrefix("event:") {
                    eventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    dataLines.append(line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces))
                }
            }
            // The server closed the stream without throwing.
            handleDisconnect("stream closed")
        } catch {
            if Task.isCancelled || stopped { return } // stop() during connect
            handleDisconnect("connect failed: \(error)")
        }
    }

    private func dispatch(event: String?, data: String) {
        var json: [String: Any]?
        if !data.isEmpty, let jsonData = data.data(using: .utf8) {
            json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        }

        switch event {
        case "connected":
            reconnectAttempt = 0 // confirmed connection — reset backoff
            onConnectionStateChanged(.connected)
            onEvent(
                .connected(
                    sdkConnectionId: json?["sdkConnectionId"] as? String ?? "",
                    deviceId: json?["deviceId"] as? String ?? ""
                ))
        case "campaign_test":
            onEvent(
                .campaignTest(
                    LiveTestInvocation(
                        testInvocationId: json?["testInvocationId"] as? String ?? "",
                        campaignId: json?["campaignId"] as? String ?? "",
                        campaign: json?["campaign"] as? [String: Any],
                        variables: json?["variables"] as? [String: Any] ?? [:]
                    )))
        case "error":
            let raw = json?["message"] as? String
            let message = (raw?.isEmpty == false) ? raw! : "live test stream error"
            onEvent(.streamError(message))
            // Per the backend doc's "Implemented exception": an `error` event
            // on the SDK connect route means the stream never really
            // connected (bad key/env/device-id) — treat it like any other
            // disconnect and back off before retrying.
            handleDisconnect("server error event: \(message)")
        default:
            break // unknown/future event types are ignored, not fatal.
        }
    }

    private func handleDisconnect(_ reason: String) {
        connectTask = nil
        if stopped {
            onConnectionStateChanged(.disconnected)
            return
        }
        onConnectionStateChanged(.error)
        DigiaLog.warning("live test stream disconnected: \(reason)")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delayMs = reconnectDelayMs(attempt: reconnectAttempt, jitterMs: Int.random(in: 0..<500))
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard let self, !self.stopped else { return }
            self.connect()
        }
    }

    private static func deviceModel() -> String {
        var sysInfo = utsname()
        uname(&sysInfo)
        return withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

/// Exponential backoff with jitter: 1s, 2s, 4s .. capped at 30s, plus up to
/// 500ms of `jitterMs` to avoid every disconnected client retrying in
/// lockstep. Pulled out as a pure function so the sequence is unit-testable
/// without touching URLSession/Tasks.
func reconnectDelayMs(attempt: Int, jitterMs: Int) -> Int {
    let baseMs = 1000 * (1 << min(max(attempt, 0), 5))
    return min(max(baseMs, 1000), 30000) + jitterMs
}
