import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger("liveTest")

/// Posts `received`/`shown`/`failed` ACKs for a live-test invocation.
///
/// Fire-and-forget at the call site — a failed post never throws — but not
/// fire-and-forget on the wire. The ACK is the *only* thing that moves a
/// dashboard row off "waiting", so a single dropped POST on a flaky office
/// network is indistinguishable, to the PM, from a campaign that never fired.
/// Hence the retries below.
@MainActor
final class LiveTestAckReporter {
    /// Longest `reason.message` we will send. Debug-only free text, and the
    /// one field an exception's description flows into — bounded so a
    /// stack-shaped message cannot become the payload.
    private static let maxMessageLength = 200

    private let sender: any AnalyticsSender
    private var config: DigiaConfig?
    private var deviceId: String?

    /// Pauses between attempts — three attempts in total, all inside the
    /// backend's 30s alarm so a recovered ACK still beats it. Overridable for
    /// tests only; production never changes this.
    var retryPauses: [TimeInterval] = [2, 5]

    init(sender: any AnalyticsSender = URLSessionAnalyticsSender()) {
        self.sender = sender
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

    /// Posts `body` to the ACK endpoint, retrying only what retrying can fix.
    ///
    /// Out-of-order arrival is safe by construction: the backend's invocation
    /// state machine ignores a transition that is not forward, so a
    /// `received` that lands after the `failed` it preceded changes nothing.
    private func post(_ body: [String: Any]) {
        guard let config else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var headers = ["Content-Type": "application/json", "x-digia-project-id": config.apiKey]
        if let deviceId { headers["x-digia-device-id"] = deviceId }

        let testInvocationId = body["testInvocationId"] as? String ?? ""
        let kind = body["status"] as? String ?? ""
        let pauses = retryPauses

        Task { [sender] in
            for attempt in 0...pauses.count {
                if attempt > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(max(pauses[attempt - 1], 0) * 1_000_000_000))
                }
                let isLastAttempt = attempt == pauses.count
                do {
                    let statusCode = try await sender.post(
                        url: DigiaEndpoints.liveTestAck, body: data, headers: headers)
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
