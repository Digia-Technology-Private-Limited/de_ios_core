import Foundation
import Testing
@testable import DigiaEngage

/// Fake sender shared across the live-test suites — records every posted
/// body, distinct from `FakeComponentSender` (`ComponentRegistryServiceTests.swift`).
final class FakeAckSender: AnalyticsSender, @unchecked Sendable {
    private(set) var bodies: [[String: Any]] = []

    func post(url: String, body: Data, headers: [String: String]) async throws -> Int {
        if let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            bodies.append(parsed)
        }
        return 200
    }
}

@MainActor
@Suite("LiveTestContext", .serialized)
struct LiveTestContextTests {
    private func reporter() -> (LiveTestAckReporter, FakeAckSender) {
        let sender = FakeAckSender()
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")
        return (reporter, sender)
    }

    /// Fire-and-forget sends run on an unstructured Task, so tests give it a
    /// short beat to complete rather than awaiting it directly.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    @Test("reportShown posts once and calls onTerminal")
    func reportShownPostsOnce() async throws {
        let (reporter, sender) = reporter()
        var terminalCalls = 0
        let context = LiveTestContext(testInvocationId: "test_1", reporter: reporter) { terminalCalls += 1 }

        context.reportShown()
        context.reportShown() // second call must be a no-op
        try await settle()

        #expect(sender.bodies.count == 1)
        #expect(sender.bodies[0]["status"] as? String == "shown")
        #expect(terminalCalls == 1)
    }

    @Test("reportFailed posts once and is exclusive with reportShown")
    func reportFailedPostsOnce() async throws {
        let (reporter, sender) = reporter()
        var terminalCalls = 0
        let context = LiveTestContext(testInvocationId: "test_2", reporter: reporter) { terminalCalls += 1 }

        context.reportFailed(.renderError, message: "boom")
        context.reportShown() // must not override the already-reported terminal outcome
        try await settle()

        #expect(sender.bodies.count == 1)
        let body = sender.bodies[0]
        #expect(body["status"] as? String == "failed")
        let reason = body["reason"] as? [String: Any]
        #expect(reason?["code"] as? String == "render_error")
        #expect(reason?["message"] as? String == "boom")
        #expect(terminalCalls == 1)
    }
}
