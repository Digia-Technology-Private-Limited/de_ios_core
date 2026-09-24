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

    @Test("report sends post request to session endpoint with correct headers and payload")
    func reportSendsCorrectPayloadAndHeaders() async throws {
        let mock = MockNetworkClient()
        mock.enqueueResponse(statusCode: 200, body: Data("{}".utf8))
        let (storage, _) = makeIsolatedStorage()

        let reporter = SessionReporter(
            apiKey: "test-api-key",
            sessionId: { "sess-123" },
            anonymousId: { "anon-456" },
            userId: { "user-789" },
            context: ["sdk_version": "1.0.0", "platform": "ios"],
            requestHeaders: [:],
            networkClient: mock,
            storage: storage
        )

        reporter.report()
        // Wait briefly for background Task to execute
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(mock.recordedRequests.count == 1)
        let request = mock.recordedRequests[0]
        #expect(request.url.absoluteString.hasSuffix("/engage/sdk/session"))
        #expect(request.headers["X-Digia-Project-Id"] == "test-api-key")
        #expect(request.headers["X-Digia-Device-Id"] == "anon-456")

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
            apiKey: "test-api-key",
            sessionId: { "sess-123" },
            anonymousId: { "anon-456" },
            userId: { nil },
            context: [:],
            requestHeaders: [:],
            networkClient: mock,
            storage: storage
        )

        reporter.report()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(mock.recordedRequests.count == 1)
        let savedReport = storage.scoped("session").string(forKey: "pending_session_report")
        #expect(savedReport != nil)

        // Second report succeeds — should flush pending and dispatch new
        mock.enqueueResponse(statusCode: 200, body: Data("{}".utf8))
        mock.enqueueResponse(statusCode: 200, body: Data("{}".utf8))

        reporter.report()
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(mock.recordedRequests.count == 3)
        #expect(storage.scoped("session").string(forKey: "pending_session_report") == nil)
    }
}
