import Foundation

private let log = DigiaLogger("analytics")

final class SessionReporter: @unchecked Sendable {
    static let keyPendingReport = "pending_session_report"

    private let apiKey: String
    private let sessionId: @Sendable () -> String
    private let anonymousId: @Sendable () -> String
    private let userId: @Sendable () -> String?
    private let context: [String: Any]
    private let requestHeaders: [String: String]
    private let networkClient: any NetworkClient
    private let storage: LocalStorage

    init(
        apiKey: String,
        sessionId: @escaping @Sendable () -> String,
        anonymousId: @escaping @Sendable () -> String,
        userId: @escaping @Sendable () -> String?,
        context: [String: Any],
        requestHeaders: [String: String] = [:],
        networkClient: any NetworkClient,
        storage: LocalStorage
    ) {
        self.apiKey = apiKey
        self.sessionId = sessionId
        self.anonymousId = anonymousId
        self.userId = userId
        self.context = context
        self.requestHeaders = requestHeaders
        self.networkClient = networkClient
        self.storage = storage
    }

    func report() {
        Task { [weak self] in
            guard let self else { return }
            await self.flushPending()
            await self.dispatch()
        }
    }

    /// Retries reports that failed earlier, without reporting a new session.
    func flush() {
        Task { [weak self] in
            await self?.flushPending()
        }
    }

    private func flushPending() async {
        guard let pendingDataStr = storage.string(forKey: Self.keyPendingReport),
              let pendingData = pendingDataStr.data(using: .utf8),
              let url = URL(string: DigiaEndpoints.session) else {
            return
        }

        var headers = requestHeaders
        headers["Content-Type"] = "application/json"
        headers["X-Digia-Project-Id"] = apiKey
        headers["X-Digia-Device-Id"] = anonymousId()

        do {
            let request = NetworkRequest(url: url, method: .post, headers: headers, body: pendingData)
            let response = try await networkClient.execute(request: request)
            if response.isSuccessful {
                storage.remove(forKey: Self.keyPendingReport)
            }
        } catch {
            log.d("Pending session report flush deferred cause=\(error.localizedDescription)")
        }
    }

    private func dispatch() async {
        let sid = sessionId()
        let aid = anonymousId()
        guard let url = URL(string: DigiaEndpoints.session) else { return }

        var body: [String: Any] = [
            "session_id": sid,
            "anonymous_id": aid,
            "occurred_at": isoNow(),
            "properties": context,
        ]
        if let uid = userId() {
            body["user_id"] = uid
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var headers = requestHeaders
        headers["Content-Type"] = "application/json"
        headers["X-Digia-Project-Id"] = apiKey
        headers["X-Digia-Device-Id"] = aid

        do {
            let request = NetworkRequest(url: url, method: .post, headers: headers, body: bodyData)
            let response = try await networkClient.execute(request: request)
            if response.isSuccessful {
                storage.remove(forKey: Self.keyPendingReport)
                log.d("Session posted (status=\(response.statusCode), sessionId=\(sid), anonymousId=\(aid))")
            } else {
                if let str = String(data: bodyData, encoding: .utf8) {
                    storage.setString(str, forKey: Self.keyPendingReport)
                }
                log.e("Session post failed (status=\(response.statusCode))")
            }
        } catch {
            if let str = String(data: bodyData, encoding: .utf8) {
                storage.setString(str, forKey: Self.keyPendingReport)
            }
            log.d("Session posted (status=-1, sessionId=\(sid), anonymousId=\(aid))")
        }
    }

    private func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
