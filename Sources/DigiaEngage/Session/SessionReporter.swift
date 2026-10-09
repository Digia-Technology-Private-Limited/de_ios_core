import Foundation

private let log = DigiaLogger("analytics")

final class SessionReporter: @unchecked Sendable {
    static let keyPendingReport = "pending_session_report"

    private let sessionId: @Sendable () -> String
    private let anonymousId: @Sendable () -> String
    private let userId: @Sendable () -> String?
    private let context: [String: Any]
    private let networkClient: any NetworkClient
    private let storage: LocalStorage
    private let connectivityMonitor: (any ConnectivityMonitor)?

    init(
        sessionId: @escaping @Sendable () -> String,
        anonymousId: @escaping @Sendable () -> String,
        userId: @escaping @Sendable () -> String?,
        context: [String: Any],
        networkClient: any NetworkClient,
        storage: LocalStorage,
        connectivityMonitor: (any ConnectivityMonitor)? = nil
    ) {
        self.sessionId = sessionId
        self.anonymousId = anonymousId
        self.userId = userId
        self.context = context
        self.networkClient = networkClient
        self.storage = storage
        self.connectivityMonitor = connectivityMonitor
    }

    /// Pending reports kept for retry (D9). Past the cap the oldest is dropped.
    static let pendingCap = 20

    private let lock = NSLock()
    /// The last scheduled operation. Each new one waits for it, so reports
    /// and flushes run one at a time, in call order, and never race on the
    /// persisted pending list.
    private var tail: Task<Void, Never>?

    /// True while [connectivityMonitor] watches for a recovery. Guarded by [lock].
    private var monitoring = false
    /// Set by [dispose]: a torn-down graph starts no new watch. Guarded by [lock].
    private var disposed = false

    /// Retries pending reports, oldest first, then reports the current session.
    /// Returns the scheduled work (nil when no body could be built), so a
    /// caller can await it; production callers ignore it.
    @discardableResult
    func report() -> Task<Void, Never>? {
        // Built now, not when the queued operation runs: a later rotation must
        // not rewrite which session this report is about.
        guard let body = makeBody() else { return nil }
        return serialize { reporter in
            // Saved before it is sent, so a process death mid-send can't lose it
            // (the server drops repeats by session_id). It queues behind older
            // reports; the flush removes it once delivered, and a failure simply
            // leaves it there.
            reporter.appendPending(body)
            reporter.syncConnectivity(await reporter.flushPending())
        }
    }

    /// Retries reports that failed earlier, without reporting a new session.
    /// Returns the scheduled work, so a caller can await it.
    @discardableResult
    func flush() -> Task<Void, Never> {
        serialize { reporter in
            reporter.syncConnectivity(await reporter.flushPending())
        }
    }

    /// Stops the connectivity watch; a torn-down graph sends nothing more.
    func dispose() {
        lock.withLock { disposed = true }
        syncConnectivity(true)
    }

    /// Watches for the network coming back exactly while reports wait: started when a
    /// flush leaves the list non-empty, stopped when the list is empty. The recovery
    /// callback serializes behind any in-flight send.
    private func syncConnectivity(_ complete: Bool) {
        lock.withLock {
            if complete {
                if monitoring {
                    monitoring = false
                    connectivityMonitor?.stop()
                }
            } else if !monitoring, !disposed {
                monitoring = true
                connectivityMonitor?.start { [weak self] in self?.flush() }
            }
        }
    }

    private func serialize(_ operation: @escaping @Sendable (SessionReporter) async -> Void) -> Task<Void, Never> {
        lock.withLock {
            let previous = tail
            let task = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                await operation(self)
            }
            tail = task
            return task
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
        // A torn-down graph posts nothing more, even from a queued recovery.
        while !lock.withLock({ disposed }), let next = loadPending().first {
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
        do {
            let request = NetworkRequest(
                url: url, method: .post, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
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
              let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any]
        else { return [] }
        return list.compactMap { $0 as? String }
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
