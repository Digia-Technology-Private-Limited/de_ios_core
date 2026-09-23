import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger("liveTest")

/// The device's uplink for one live-test invocation.
///
/// Fire-and-forget at the call site — a failed post never throws — but not
/// fire-and-forget on the wire. The ACK is the *only* thing that moves a
/// dashboard row off "waiting", so a single dropped POST on a flaky office
/// network is indistinguishable, to the PM, from a campaign that never fired.
/// Hence the retries below.
///
/// Two kinds of message ride it, and the difference matters:
///
/// - **ACKs** (``postReceived``/``postShown``/``postFailed``) drive the
///   invocation's state machine. Exactly one terminal ACK per invocation, and
///   the backend refuses to overwrite it.
/// - **Events** (``postEvent``) are live-only colour — what the user
///   answered, how they dismissed it. The backend stores none of it; it looks
///   the invocation up only to check ownership, then republishes to the
///   dashboard that started the test. If nobody is watching, it evaporates,
///   and that is the whole intent.
@MainActor
final class LiveTestAckReporter {
    /// Longest `reason.message` we will send. Debug-only free text, and the
    /// one field an exception's description flows into — bounded so a
    /// stack-shaped message cannot become the payload.
    private static let maxMessageLength = 200

    private let networkClient: any NetworkClient
    private var config: DigiaConfig?
    private var deviceId: String?

    /// Pauses between attempts — three attempts in total, all inside the
    /// backend's 30s alarm so a recovered ACK still beats it. Overridable for
    /// tests only; production never changes this.
    var retryPauses: [TimeInterval] = [2, 5]

    init(networkClient: any NetworkClient = URLSessionNetworkClient()) {
        self.networkClient = networkClient
    }

    convenience init(sender: any NetworkClient) {
        self.init(networkClient: sender)
    }

    func configure(config: DigiaConfig, deviceId: String) {
        self.config = config
        self.deviceId = deviceId
    }

    func postReceived(_ testInvocationId: String) {
        post(["testInvocationId": testInvocationId, "status": "received"])
    }

    func postShown(_ testInvocationId: String) {
        post(["testInvocationId": testInvocationId, "status": "shown"])
    }

    func postFailed(_ testInvocationId: String, code: DiagnosticReason, message: String? = nil) {
        var reason: [String: Any] = ["code": code.wire]
        if let bounded = Self.bound(message) { reason["message"] = bounded }
        post(["testInvocationId": testInvocationId, "status": "failed", "reason": reason])
    }

    /// Sends a live-only event for an invocation that is already in flight.
    ///
    /// Deliberately *not* an ACK status: a survey submission and a dismissal
    /// both happen **after** `shown`, which is terminal. Modelling them as
    /// transitions would mean reopening a state machine whose entire value is
    /// that it closes exactly once.
    func postEvent(_ testInvocationId: String, type: String, payload: [String: Any]) {
        post(
            ["testInvocationId": testInvocationId, "type": type, "payload": payload],
            endpoint: DigiaEndpoints.liveTestEvent
        )
    }

    /// Posts `body` to `endpoint`, retrying only what retrying can fix.
    ///
    /// Out-of-order arrival is safe by construction: the backend's invocation
    /// state machine ignores a transition that is not forward, so a
    /// `received` that lands after the `failed` it preceded changes nothing.
    private func post(_ body: [String: Any], endpoint: String = DigiaEndpoints.liveTestAck) {
        guard let config else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var headers = ["Content-Type": "application/json", "x-digia-project-id": config.apiKey]
        if let deviceId { headers["x-digia-device-id"] = deviceId }

        let testInvocationId = body["testInvocationId"] as? String ?? ""
        let kind = (body["status"] as? String) ?? (body["type"] as? String) ?? ""
        let pauses = retryPauses
        let client = networkClient

        Task {
            for attempt in 0...pauses.count {
                if attempt > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(max(pauses[attempt - 1], 0) * 1_000_000_000))
                }
                let isLastAttempt = attempt == pauses.count
                do {
                    guard let url = URL(string: endpoint) else { return }
                    let request = NetworkRequest(url: url, method: .post, headers: headers, body: data)
                    let response = try await client.execute(request: request)
                    let statusCode = response.statusCode
                    if (200...299).contains(statusCode) {
                        log.d(
                            "Uplink posted (status=\(statusCode), invocationId=\(testInvocationId), "
                                + "kind=\(kind), attempt=\(attempt + 1))")
                        return
                    }
                    // A 4xx is a verdict, not a hiccup — an unknown or expired
                    // invocation, or a key the backend refuses. The same bytes
                    // will be refused again, so retrying only delays the give
                    // up. Anything 5xx is a hiccup and keeps retrying.
                    if statusCode < 500 {
                        log.w(
                            "Uplink post refused — giving up (status=\(statusCode), "
                                + "invocationId=\(testInvocationId), kind=\(kind))")
                        return
                    }
                    if isLastAttempt {
                        log.w(
                            "Uplink post failed after \(attempt + 1) attempts — continuing "
                                + "(invocationId=\(testInvocationId), kind=\(kind), status=\(statusCode))"
                        )
                        return
                    }
                } catch {
                    if isLastAttempt {
                        log.e(
                            "Uplink post failed after \(attempt + 1) attempts — continuing "
                                + "(invocationId=\(testInvocationId), kind=\(kind))",
                            error: error)
                        return
                    }
                    // A network error is a hiccup — keep retrying.
                }
            }
        }
    }

    private static func bound(_ message: String?) -> String? {
        guard let message, !message.isEmpty else { return nil }
        guard message.count > maxMessageLength else { return message }
        return String(message.prefix(maxMessageLength)) + "…"
    }
}
