import Foundation
import UIKit
import Testing
@testable import DigiaEngage

/// Service behavior that exists only on iOS: background task time, and the
/// typed `captureHealth` signature. Everything shared with Android and Flutter
/// is in `AnalyticsServiceTests`.
@MainActor
@Suite("AnalyticsService (iOS)", .serialized)
struct AnalyticsServiceIOSTests {

    private func makeService(
        config: AnalyticsConfig = AnalyticsConfig(flushIntervalMs: 10_000),
        sender: any NetworkClient = FakeAnalyticsSender(),
        backgroundTime: BackgroundTimeProvider = FakeBackgroundTime()
    ) -> AnalyticsService {
        makeTestAnalyticsService(config: config, sender: sender, backgroundTime: backgroundTime)
    }

    private func buildPayload(_ campaignKey: String) -> CEPTriggerPayload { testPayload(campaignKey) }

    private func waitUntil(_ condition: () -> Bool) async throws { try await waitForAnalytics(condition) }

    @Test("the background flush runs inside one background task, ended when it finishes")
    func backgroundFlushHoldsBackgroundTime() async throws {
        let sender = FakeAnalyticsSender()
        sender.responseDelayMs = 50
        let time = FakeBackgroundTime()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: sender,
            backgroundTime: time
        )
        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await waitUntil { sender.callCount == 1 }
        #expect(time.begun == 1)
        #expect(time.ended.isEmpty, "held while the send is in flight")

        try await waitUntil { service.queue.size == 0 && time.ended.count == 1 }
        #expect(time.ended == [1])
    }

    @Test("an expiring background task is ended at once, and only once")
    func expiringBackgroundTimeEndsOnce() async throws {
        let sender = FakeAnalyticsSender()
        sender.responseDelayMs = 200
        let time = FakeBackgroundTime()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: sender,
            backgroundTime: time
        )
        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await waitUntil { sender.callCount == 1 }
        time.expire()
        #expect(time.ended == [1], "ended when iOS says time is up")

        try await waitUntil { service.queue.size == 0 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(time.ended == [1], "not ended again when the send finishes")
    }

    @Test("captureHealth carries stage and detail only when present")
    func captureHealthOptionalFields() async {
        let service = makeService()

        service.captureHealth(
            campaignKey: nil,
            reason: "fetch_failed_auth",
            stage: nil,
            detail: ["http_status": "401"],
            buildMode: "release"
        )

        let entry = await service.queue.peek(maxCount: 1)[0].payload
        #expect(entry["campaign_key"] == nil)
        let props = entry["properties"] as? [String: Any]
        #expect(props?["stage"] == nil)
        #expect((props?["detail"] as? [String: String]) == ["http_status": "401"])
    }
}
