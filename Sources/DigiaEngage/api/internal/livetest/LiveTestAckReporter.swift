import Foundation

/// Posts `received` / `shown` / `failed` ACKs to `POST .../testInvocation/ack`.
/// Fire-and-forget: a failed post is logged and swallowed, not surfaced.
@MainActor
final class LiveTestAckReporter {
    private let sender: any AnalyticsSender
    private var config: DigiaConfig?
    private var deviceId: String?

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

    func postFailed(_ testInvocationId: String, code: LiveTestFailureCode, message: String? = nil) {
        var reason: [String: Any] = ["code": code.wireValue]
        if let message { reason["message"] = message }
        post(["testInvocationId": testInvocationId, "status": "failed", "reason": reason])
    }

    private func post(_ body: [String: Any]) {
        guard let config else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var headers = ["Content-Type": "application/json", "x-digia-project-id": config.apiKey]
        if let deviceId { headers["x-digia-device-id"] = deviceId }

        let testInvocationId = body["testInvocationId"] as? String ?? ""
        let status = body["status"] as? String ?? ""
        Task { [sender] in
            do {
                let code = try await sender.post(url: DigiaEndpoints.liveTestAck, body: data, headers: headers)
                DigiaLog.log(
                    "testInvocation/ack HTTP \(code) (testInvocationId=\(testInvocationId), status=\(status))"
                )
            } catch {
                DigiaLog.warning("testInvocation/ack post failed: \(error)")
            }
        }
    }
}
