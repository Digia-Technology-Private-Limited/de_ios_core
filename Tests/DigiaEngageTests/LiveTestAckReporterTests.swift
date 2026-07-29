import Foundation
import Testing
@testable import DigiaEngage

@MainActor
@Suite("LiveTestAckReporter", .serialized)
struct LiveTestAckReporterTests {
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    @Test("does nothing before configure is called")
    func doesNothingBeforeConfigure() async throws {
        let sender = FakeAckSender()
        let reporter = LiveTestAckReporter(sender: sender)

        reporter.postReceived("test_1")
        try await settle()

        #expect(sender.bodies.isEmpty)
    }

    @Test("postReceived sends the testInvocationId and status")
    func postReceivedSendsFields() async throws {
        let sender = FakeAckSender()
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "digia_test"), deviceId: "device-42")

        reporter.postReceived("test_1")
        try await settle()

        let body = try #require(sender.bodies.first)
        #expect(body["testInvocationId"] as? String == "test_1")
        #expect(body["status"] as? String == "received")
    }

    @Test("postFailed with no message omits the reason message field")
    func postFailedOmitsMessageWhenNil() async throws {
        let sender = FakeAckSender()
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "digia_test"), deviceId: "device-42")

        reporter.postFailed("test_1", code: .campaignNotFound)
        try await settle()

        let reason = try #require(sender.bodies.first?["reason"] as? [String: Any])
        #expect(reason["code"] as? String == "campaign_not_found")
        #expect(reason["message"] == nil)
    }
}
