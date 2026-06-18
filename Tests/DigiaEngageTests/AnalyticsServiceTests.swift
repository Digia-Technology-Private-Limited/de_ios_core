import Foundation
import UIKit
import Testing
@testable import DigiaEngage

// Campaign id/type are resolved from the campaign store at event time and passed
// into capture() by the caller; this helper supplies fixed test values so the
// existing call sites stay terse.
@MainActor
private extension AnalyticsService {
    func capture(_ event: EngageAnalyticsEvent, payload: CEPTriggerPayload) {
        capture(event, payload: payload, campaignId: "example-campaign", campaignType: "guide")
    }
}

// MARK: - Test doubles

/// Fake sender that records calls and returns a configurable status code.
final class FakeAnalyticsSender: AnalyticsSender, @unchecked Sendable {
    private var _callCount = 0
    var callCount: Int { _callCount }
    var responseFactory: (Int) -> Int

    init(responseFactory: @escaping (Int) -> Int = { _ in 200 }) {
        self.responseFactory = responseFactory
    }

    func post(url: String, body: Data, headers: [String: String]) async throws -> Int {
        _callCount += 1
        return responseFactory(_callCount)
    }
}

// MARK: - Suite

@MainActor
@Suite("AnalyticsService", .serialized)
struct AnalyticsServiceTests {

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Returns a fresh named UserDefaults suite (isolated per test).
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "digia.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func makeService(
        config: AnalyticsConfig = AnalyticsConfig(flushIntervalMs: 10_000),
        sender: FakeAnalyticsSender = FakeAnalyticsSender(),
        defaults: UserDefaults? = nil
    ) -> AnalyticsService {
        let store = defaults ?? UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
        return AnalyticsService(
            config: config,
            apiKey: "test-api-key",
            identity: AnalyticsIdentityManager(defaults: store),
            queue: AnalyticsQueue(defaults: store),
            staticContext: ["sdk_version": "1.0.0", "sdk_platform": "ios"],
            sender: sender
        )
    }

    private func buildPayload(_ campaignKey: String) -> CEPTriggerPayload {
        CEPTriggerPayload(cepCampaignId: campaignKey, campaignKey: campaignKey)
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    @Test("anonymous ID is generated and stable")
    func anonymousIdIsStable() {
        let service = makeService()
        let id1 = service.identity.anonymousId
        let id2 = service.identity.anonymousId
        #expect(!id1.isEmpty)
        #expect(id1 == id2)
    }

    @Test("setUserId persists and clearUserId rotates session")
    func setUserIdAndClearUserId() {
        let service = makeService()

        service.setUserId("user-123")
        #expect(service.identity.userId == "user-123")

        let sessionBefore = service.identity.sessionId
        service.clearUserId()

        #expect(service.identity.userId == nil)
        #expect(!service.identity.sessionId.isEmpty)
        #expect(service.identity.sessionId != sessionBefore)
    }

    @Test("queue drops oldest events when capacity is exceeded")
    func queueDropsOldestWhenFull() {
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 100, queueMaxEvents: 3)
        )

        for i in 0..<5 {
            service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("event-\(i)"))
        }

        #expect(service.queue.size == 3)
        let entries = service.queue.peek(maxCount: 10)
        // oldest two dropped; event-2, event-3, event-4 remain
        #expect(entries[0].payload["campaign_key"] as? String == "event-2")
        #expect(entries[1].payload["campaign_key"] as? String == "event-3")
        #expect(entries[2].payload["campaign_key"] as? String == "event-4")
    }

    @Test("event payload has correct structure and identity fields")
    func eventPayloadStructure() {
        let service = makeService()
        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("payload-1"))

        let entries = service.queue.peek(maxCount: 1)
        #expect(!entries.isEmpty)
        let event = entries[0].payload

        #expect(event["event_name"] as? String == "Digia Experience Viewed")
        #expect(event["campaign_id"] as? String == "example-campaign")
        #expect(event["campaign_key"] as? String == "payload-1")
        #expect(event["campaign_type"] as? String == "guide")
        #expect((event["event_id"] as? String)?.isEmpty == false)
        #expect((event["occurred_at"] as? String)?.isEmpty == false)
        #expect((event["anonymous_id"] as? String)?.isEmpty == false)
        #expect((event["session_id"] as? String)?.isEmpty == false)
        #expect(event["user_id"] == nil)   // not set — must be absent

        let props = event["properties"] as? [String: Any]
        #expect(props != nil)
        #expect(props?["sdk_version"] as? String == "1.0.0")
        #expect(props?["sdk_platform"] as? String == "ios")
    }

    @Test("event names map correctly for all experience event types")
    func eventNameMapping() {
        let service = makeService()
        let payload = buildPayload("test")

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: payload)
        service.capture(NudgeEvent.Clicked(elementId: "cta-btn"), payload: payload)
        service.capture(NudgeEvent.Dismissed(), payload: payload)

        let entries = service.queue.peek(maxCount: 10)
        #expect(entries.count == 3)
        #expect(entries[0].payload["event_name"] as? String == "Digia Experience Viewed")
        #expect(entries[1].payload["event_name"] as? String == "Digia Experience Clicked")
        #expect(entries[2].payload["event_name"] as? String == "Digia Experience Dismissed")

        // element_id is a hoisted top-level column, present only for Clicked.
        #expect(entries[1].payload["element_id"] as? String == "cta-btn")
        #expect(entries[0].payload["element_id"] == nil)
    }

    @Test("batch threshold triggers immediate flush")
    func batchThresholdTriggersFlush() async throws {
        let fakeSender = FakeAnalyticsSender()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 2),
            sender: fakeSender
        )

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p2"))
        // second capture reaches flushBatchSize — dispatch Task is enqueued; release actor to let it run
        try await Task.sleep(for: .milliseconds(50))

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 1)
    }

    @Test("timer fires after flushIntervalMs")
    func timerFiresAfterInterval() async throws {
        let fakeSender = FakeAnalyticsSender()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 50, flushBatchSize: 10),
            sender: fakeSender
        )

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        // timer scheduled for 50ms — wait well past it
        try await Task.sleep(for: .milliseconds(300))

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 1)
    }

    @Test("explicit flush() dispatches pending events")
    func explicitFlushDispatchesPending() async throws {
        let fakeSender = FakeAnalyticsSender()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: fakeSender
        )

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        #expect(service.queue.size == 1)

        service.flush()
        try await Task.sleep(for: .milliseconds(50))

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 1)
    }

    @Test("5xx response retries and event survives until success")
    func fiveXxRetrySucceeds() async throws {
        let fakeSender = FakeAnalyticsSender { callNum in callNum == 1 ? 500 : 200 }
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: fakeSender
        )
        service.retryScheduleMs = [10, 20]  // fast retries for the test

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()
        // let flush attempt run and fail (500) but not the retry yet (10ms)
        try await Task.sleep(for: .milliseconds(5))
        #expect(service.retryAttempt == 1)
        #expect(service.queue.size == 1)

        // let the retry fire and succeed
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.queue.size == 0)
        #expect(service.retryAttempt == 0)
        #expect(fakeSender.callCount == 2)
    }

    @Test("background notification flushes pending events")
    func backgroundNotificationFlushes() async throws {
        let fakeSender = FakeAnalyticsSender()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: fakeSender
        )

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        #expect(service.queue.size == 1)

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 1)
    }

    @Test("persisted queue flushes on next cold init")
    func persistedQueueFlushesOnColdInit() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // First session — enqueue, then simulate process death (queue persists)
        let service1 = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            defaults: defaults
        )
        service1.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("persisted"))
        #expect(service1.queue.size == 1)
        service1.resetForTest()  // cancel timers, keep queue in UserDefaults

        // Second session — same defaults, short timer
        let fakeSender = FakeAnalyticsSender()
        let service2 = makeService(
            config: AnalyticsConfig(flushIntervalMs: 50, flushBatchSize: 10),
            sender: fakeSender,
            defaults: defaults
        )

        try await Task.sleep(for: .milliseconds(300))
        _ = service2  // keep alive until timer fires

        #expect(fakeSender.callCount == 1)
        #expect(AnalyticsQueue(defaults: defaults).size == 0)
    }

    @Test("dismissed event queues but does not self-flush")
    func dismissedEventQueuesWithoutFlush() async throws {
        let fakeSender = FakeAnalyticsSender()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 100),
            sender: fakeSender
        )

        service.capture(NudgeEvent.Dismissed(), payload: buildPayload("p1"))
        // small pause to confirm no background task fires
        try await Task.sleep(for: .milliseconds(20))

        #expect(service.queue.size == 1)
        #expect(fakeSender.callCount == 0)
    }

    @Test("partial failure (207) removes all batched events without retry")
    func partialFailureRemovesAllEvents() async throws {
        let fakeSender = FakeAnalyticsSender { _ in 207 }
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: fakeSender
        )

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.capture(NudgeEvent.Clicked(elementId: "cta"), payload: buildPayload("p2"))

        service.flush()
        try await Task.sleep(for: .milliseconds(50))

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 1)
    }
}
