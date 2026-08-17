import Foundation

/// One parsed SSE event from the live-test connect stream.
enum LiveTestSseEvent {
    case connected(sdkConnectionId: String, deviceId: String)
    case campaignTest(LiveTestInvocation)
    case streamError(String)
}

/// Low-level transport for `POST /api/v1/engage/sdk/live/connect`, built on
/// `URLSession.bytes(for:)`; framing is handled by `SSEFrameParser`.
@MainActor
final class LiveTestSSEClient {
    private let config: () -> DigiaConfig
    private let deviceId: () -> String
    private let deviceName: () -> String?
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
        deviceName: @escaping () -> String? = { nil },
        onEvent: @escaping (LiveTestSseEvent) -> Void,
        onConnectionStateChanged: @escaping (LiveTestConnectionState) -> Void,
        session: URLSession? = nil
    ) {
        self.config = config
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.onEvent = onEvent
        self.onConnectionStateChanged = onConnectionStateChanged
        if let session {
            self.session = session
        } else {
            let sessionConfig = URLSessionConfiguration.default
            // 45s: matches the backend's presence-lease TTL, well past its 15s heartbeat.
            sessionConfig.timeoutIntervalForRequest = 45
            self.session = URLSession(configuration: sessionConfig)
        }
    }

    func start() {
        guard stopped else { return }
        stopped = false
        reconnectAttempt = 0
        connect()
    }

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
        let body = deviceName().map { ["deviceName": $0] } ?? [:]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
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

            var parser = SSEFrameParser()
            for try await byte in bytes {
                if Task.isCancelled { return }
                if let frame = parser.feed(byte) {
                    dispatch(event: frame.event, data: frame.data)
                }
            }
            // The server closed the stream without throwing.
            handleDisconnect("stream closed")
        } catch {
            if Task.isCancelled || stopped { return }
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
            reconnectAttempt = 0
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
            handleDisconnect("server error event: \(message)")
        default:
            break
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

/// Exponential backoff with jitter: 1s, 2s, 4s .. capped at 30s.
func reconnectDelayMs(attempt: Int, jitterMs: Int) -> Int {
    let baseMs = 1000 * (1 << min(max(attempt, 0), 5))
    return min(max(baseMs, 1000), 30000) + jitterMs
}

/// Buffers raw SSE bytes into `(event, data)` frames on each blank-line boundary.
/// Not built on `bytes.lines` (`AsyncLineSequence`) — it silently drops blank
/// lines (`"a\n\nb"` yields `["a", "b"]`), so a parser waiting on `line.isEmpty` never fires.
struct SSEFrameParser {
    private var buffer = Data()
    private var eventName: String?
    private var dataLines: [String] = []

    /// Returns a completed frame once a blank-line boundary closes one, else `nil`.
    mutating func feed(_ byte: UInt8) -> (event: String?, data: String)? {
        buffer.append(byte)
        guard let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let lineData = buffer[buffer.startIndex..<newlineIndex]
        buffer.removeSubrange(buffer.startIndex...newlineIndex)
        var line = String(decoding: lineData, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            defer {
                eventName = nil
                dataLines = []
            }
            guard eventName != nil || !dataLines.isEmpty else { return nil }
            return (eventName, dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil } // heartbeat comment
        if line.hasPrefix("event:") {
            eventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
