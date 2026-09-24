import Foundation
import Testing

@testable import DigiaEngage

@Suite("SessionReporter unit tests", .serialized)
struct SessionReporterTests {

    private func makeIsolatedStorage() -> (LocalStorage, UserDefaults) {
        let suiteName = "test_reporter_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let storage = UserDefaultsLocalStorage(defaults: defaults)
        return (storage, defaults)
    }

    /// Reports post from a background task; polls instead of guessing a delay.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func pendingCount(_ storage: LocalStorage) -> Int {
        guard let raw = storage.scoped("session").string(forKey: "pending_session_report"),
              let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any]
        else { return 0 }
        return list.count
    }

    @Test("report sends post request to session endpoint with correct headers and payload")
    func reportSendsCorrectPayloadAndHeaders() async throws {
        let mock = MockNetworkClient()
        mock.enqueueResponse(statusCode: 200, body: Data("{}".utf8))
        let (storage, _) = makeIsolatedStorage()

        let reporter = SessionReporter(
            sessionId: { "sess-123" },
            anonymousId: { "anon-456" },
            userId: { "user-789" },
            context: ["sdk_version": "1.0.0", "platform": "ios"],
            networkClient: mock,
            storage: storage.scoped("session")
        )

        reporter.report()
        try await waitUntil { mock.requestCount >= 1 }

        #expect(mock.recordedRequests.count == 1)
        let request = try #require(mock.recordedRequests.first)
        #expect(request.url.absoluteString.hasSuffix("/engage/sdk/session"))
        // Protocol headers only: the client adds Project-Id and Device-Id.
        #expect(request.headers == ["Content-Type": "application/json"])

        let bodyData = try #require(request.body)
        let bodyJson = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyJson["session_id"] as? String == "sess-123")
        #expect(bodyJson["anonymous_id"] as? String == "anon-456")
        #expect(bodyJson["user_id"] as? String == "user-789")
        #expect(bodyJson["occurred_at"] != nil)

        let props = try #require(bodyJson["properties"] as? [String: Any])
        #expect(props["sdk_version"] as? String == "1.0.0")
        #expect(props["platform"] as? String == "ios")

        #expect(storage.scoped("session").string(forKey: "pending_session_report") == nil)
    }

    @Test("failed report persists to storage and is retried on next report")
    func failedReportPersistsAndRetries() async throws {
        let mock = MockNetworkClient()
        // First report fails with 500
        mock.enqueueResponse(statusCode: 500, body: Data("Internal Server Error".utf8))
        let (storage, _) = makeIsolatedStorage()

        let reporter = SessionReporter(
            sessionId: { "sess-123" },
            anonymousId: { "anon-456" },
            userId: { nil },
            context: [:],
            networkClient: mock,
            storage: storage.scoped("session")
        )

        reporter.report()
        try await waitUntil { pendingCount(storage) == 1 }

        #expect(mock.recordedRequests.count == 1)
        let savedReport = storage.scoped("session").string(forKey: "pending_session_report")
        #expect(savedReport != nil)

        // Second report succeeds — should flush pending and dispatch new
        mock.enqueueResponse(statusCode: 200, body: Data("{}".utf8))
        mock.enqueueResponse(statusCode: 200, body: Data("{}".utf8))

        reporter.report()
        try await waitUntil { mock.requestCount >= 3 && pendingCount(storage) == 0 }

        #expect(mock.recordedRequests.count == 3)
        #expect(storage.scoped("session").string(forKey: "pending_session_report") == nil)
    }

    private func postedSessionIds(_ mock: MockNetworkClient) -> [String] {
        mock.recordedRequests.compactMap { request in
            request.body
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["session_id"] as? String }
        }
    }

    @Test("reports that failed offline are posted in order once the network is back")
    func pendingReportsFlushInOrder() async throws {
        let mock = MockNetworkClient()
        mock.simulateTransportError(URLError(.notConnectedToInternet))
        let (storage, _) = makeIsolatedStorage()
        let currentSession = LockedBox("s1")
        let reporter = SessionReporter(
            sessionId: { currentSession.value },
            anonymousId: { "anon" },
            userId: { nil },
            context: [:],
            networkClient: mock,
            storage: storage.scoped("session")
        )

        for id in ["s1", "s2", "s3"] {
            currentSession.mutate { $0 = id }
            reporter.report()
        }
        try await waitUntil { pendingCount(storage) == 3 }

        mock.reset()
        mock.setResponseFactory { _ in NetworkResponse(statusCode: 200, headers: [:], body: Data()) }
        reporter.flush()
        try await waitUntil { postedSessionIds(mock).count >= 3 }

        #expect(postedSessionIds(mock) == ["s1", "s2", "s3"])
        #expect(storage.scoped("session").string(forKey: "pending_session_report") == nil)
    }

    @Test("a 4xx report is dropped, 408/429 are kept, and the list is capped oldest-first")
    func pendingListRules() async throws {
        let mock = MockNetworkClient()
        let status = LockedBox(400)
        mock.setResponseFactory { _ in NetworkResponse(statusCode: status.value, headers: [:], body: Data()) }
        let (storage, _) = makeIsolatedStorage()
        let currentSession = LockedBox("s0")
        let reporter = SessionReporter(
            sessionId: { currentSession.value },
            anonymousId: { "anon" },
            userId: { nil },
            context: [:],
            networkClient: mock,
            storage: storage.scoped("session")
        )

        reporter.report()
        try await waitUntil { mock.requestCount >= 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(storage.scoped("session").string(forKey: "pending_session_report") == nil)

        status.mutate { $0 = 429 }
        for index in 1...(SessionReporter.pendingCap + 2) {
            currentSession.mutate { $0 = "s\(index)" }
            reporter.report()
        }
        reporter.flush()
        try await waitUntil { mock.requestCount >= SessionReporter.pendingCap + 4 }

        mock.reset()
        mock.setResponseFactory { _ in NetworkResponse(statusCode: 200, headers: [:], body: Data()) }
        reporter.flush()
        try await waitUntil { postedSessionIds(mock).count >= SessionReporter.pendingCap }

        let expected = (3...(SessionReporter.pendingCap + 2)).map { "s\($0)" }
        #expect(postedSessionIds(mock) == expected)
    }
}

