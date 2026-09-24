import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger("liveTest")

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
    private let requestHeaders: [String: String]
    private let deviceName: () -> String?
    private let onEvent: (LiveTestSseEvent) -> Void
    private let onConnectionStateChanged: (LiveTestConnectionState) -> Void
    private let networkClient: any NetworkClient

    private var sseSubscription: (any CancellableSubscription)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var stopped = true

    var isRunning: Bool { !stopped }

    init(
        config: @escaping () -> DigiaConfig,
        deviceId: @escaping () -> String,
        requestHeaders: [String: String],
        deviceName: @escaping () -> String?,
        onEvent: @escaping (LiveTestSseEvent) -> Void,
        onConnectionStateChanged: @escaping (LiveTestConnectionState) -> Void,
        networkClient: any NetworkClient
    ) {
        self.config = config
        self.deviceId = deviceId
        self.requestHeaders = requestHeaders
        self.deviceName = deviceName
        self.onEvent = onEvent
        self.onConnectionStateChanged = onConnectionStateChanged
        self.networkClient = networkClient
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
        sseSubscription?.cancel()
        sseSubscription = nil
        onConnectionStateChanged(.disconnected)
    }

    private func connect() {
        guard !stopped else { return }
        onConnectionStateChanged(.connecting)
        let cfg = config()
        guard let url = URL(string: DigiaEndpoints.liveTestConnect) else {
            handleDisconnect("invalid live test URL")
            return
        }

        let bodyDict = deviceName().map { ["deviceName": $0] } ?? [:]
        let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict)

        var headers = requestHeaders
        headers["Content-Type"] = "application/json"
        headers["X-Digia-Project-Id"] = cfg.apiKey
        headers["X-Digia-Device-Id"] = deviceId()
        headers["X-Digia-Environment"] = "debug"
        headers["X-Digia-Platform"] = "ios"
        headers["X-Digia-Version"] = DigiaSdkVersion.value
        headers["X-Digia-Device-Make"] = "Apple"
        headers["X-Digia-Device-Model"] = Self.deviceModel()

        let request = NetworkRequest(
            url: url,
            method: .post,
            headers: headers,
            body: bodyData,
            connectTimeout: 45,
            readTimeout: 45
        )

        let handler = LiveTestSseStreamHandler(
            onEvent: { [weak self] event in
                self?.dispatch(event: event.event, data: event.data)
            },
            onOpen: { [weak self] in
                self?.reconnectAttempt = 0
            },
            onError: { [weak self] error in
                guard let self else { return }
                if let status = (error as? SseHTTPStatusError)?.statusCode, status == 401 || status == 403 {
                    self.handleAuthRejected(status: status)
                } else {
                    self.handleDisconnect("connect failed: \(error)")
                }
            },
            onClosed: { [weak self] in
                self?.handleDisconnect("stream closed")
            }
        )

        sseSubscription = networkClient.openSseStream(request: request, handler: handler)
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
            log.i(
                "Stream connected (deviceId=\(json?["deviceId"] as? String ?? ""))",
                stage: .session,
                reason: TimelineReason.liveSessionConnected
            )
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
        sseSubscription?.cancel()
        sseSubscription = nil
        if stopped {
            onConnectionStateChanged(.disconnected)
            return
        }
        onConnectionStateChanged(.error)
        log.w(
            "Stream disconnected — reconnecting (reason=\(reason))",
            stage: .session,
            reason: TimelineReason.liveSessionDisconnected
        )
        scheduleReconnect()
    }

    /// Reconnecting cannot fix a rejected key, so the loop stops here. A later
    /// `start()` (re-enable, or the app returning to foreground) tries again.
    private func handleAuthRejected(status: Int) {
        sseSubscription?.cancel()
        sseSubscription = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        stopped = true
        onConnectionStateChanged(.error)
        log.e(
            "Stream rejected — not reconnecting (status=\(status))",
            stage: .session,
            reason: TimelineReason.liveSessionDisconnected
        )
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

private final class LiveTestSseStreamHandler: SseStreamHandler, @unchecked Sendable {
    private let onEventHandler: @MainActor (SseEvent) -> Void
    private let onOpenHandler: @MainActor () -> Void
    private let onErrorHandler: @MainActor (Error) -> Void
    private let onClosedHandler: @MainActor () -> Void

    init(
        onEvent: @escaping @MainActor (SseEvent) -> Void,
        onOpen: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void,
        onClosed: @escaping @MainActor () -> Void
    ) {
        self.onEventHandler = onEvent
        self.onOpenHandler = onOpen
        self.onErrorHandler = onError
        self.onClosedHandler = onClosed
    }

    func onOpen() {
        Task { @MainActor in
            self.onOpenHandler()
        }
    }

    func onEvent(_ event: SseEvent) {
        Task { @MainActor in
            self.onEventHandler(event)
        }
    }

    func onError(_ error: Error) {
        Task { @MainActor in
            self.onErrorHandler(error)
        }
    }

    func onClosed() {
        Task { @MainActor in
            self.onClosedHandler()
        }
    }
}

