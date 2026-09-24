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

    /// Pending reports kept for retry (D9). Past the cap the oldest is dropped.
    static let pendingCap = 20

    private let lock = NSLock()
    /// The last scheduled operation. Each new one waits for it, so reports
    /// and flushes run one at a time, in call order, and never race on the
    /// persisted pending list.
    private var tail: Task<Void, Never>?

    /// Retries pending reports, oldest first, then reports the current session.
    func report() {
        // Built now, not when the queued operation runs: a later rotation must
        // not rewrite which session this report is about.
        guard let body = makeBody() else { return }
        serialize { reporter in
            guard await reporter.flushPending() else {
                // Still failing: queue this report behind the others, in order.
                reporter.appendPending(body)
                return
            }
            await reporter.dispatch(body)
        }
    }

    /// Retries reports that failed earlier, without reporting a new session.
    func flush() {
        serialize { reporter in
            _ = await reporter.flushPending()
        }
    }

    private func serialize(_ operation: @escaping @Sendable (SessionReporter) async -> Void) {
        lock.withLock {
            let previous = tail
            tail = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                await operation(self)
            }
        }
    }

    private enum Outcome {
        case sent
        /// Rejected for good (a 4xx other than 408/429): retrying cannot help.
        case rejected(Int)
        /// Worth retrying later: 5xx, 408, 429, or no response at all.
        case failed(String)
    }

    /// Posts pending reports in order. Returns true when none remain.
    private func flushPending() async -> Bool {
        while let next = loadPending().first {
            switch await post(next) {
            case .sent:
                removeFirstPending()
            case let .rejected(status):
                removeFirstPending()
                log.e("Pending session report dropped (status=\(status))")
            case let .failed(cause):
                log.d("Pending session report flush deferred (cause=\(cause))")
                return false
            }
        }
        return true
    }

    private func dispatch(_ body: String) async {
        switch await post(body) {
        case .sent:
            log.d("Session posted")
        case let .rejected(status):
            log.e("Session post rejected — not retried (status=\(status))")
        case let .failed(cause):
            appendPending(body)
            log.d("Session post failed — kept for retry (cause=\(cause))")
        }
    }

    private func makeBody() -> String? {
        var body: [String: Any] = [
            "session_id": sessionId(),
            "anonymous_id": anonymousId(),
            "occurred_at": isoNow(),
            "properties": context,
        ]
        if let uid = userId() {
            body["user_id"] = uid
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func post(_ body: String) async -> Outcome {
        guard let url = URL(string: DigiaEndpoints.session) else { return .rejected(-1) }
        var headers = requestHeaders
        headers["Content-Type"] = "application/json"
        headers["X-Digia-Project-Id"] = apiKey
        headers["X-Digia-Device-Id"] = anonymousId()
        do {
            let request = NetworkRequest(url: url, method: .post, headers: headers, body: Data(body.utf8))
            let response = try await networkClient.execute(request: request)
            let status = response.statusCode
            if response.isSuccessful { return .sent }
            if (400...499).contains(status), status != 408, status != 429 { return .rejected(status) }
            return .failed("HTTP \(status)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Pending list (a JSON array of report bodies)

    private func loadPending() -> [String] {
        guard let raw = storage.string(forKey: Self.keyPendingReport),
              let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String]
        else { return [] }
        return list
    }

    private func savePending(_ list: [String]) {
        guard !list.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: list),
              let raw = String(data: data, encoding: .utf8)
        else {
            storage.remove(forKey: Self.keyPendingReport)
            return
        }
        storage.setString(raw, forKey: Self.keyPendingReport)
    }

    private func appendPending(_ body: String) {
        savePending(Array((loadPending() + [body]).suffix(Self.pendingCap)))
    }

    private func removeFirstPending() {
        savePending(Array(loadPending().dropFirst()))
    }

    private func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
