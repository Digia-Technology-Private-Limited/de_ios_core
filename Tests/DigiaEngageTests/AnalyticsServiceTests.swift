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
///
/// Only the track-dispatch endpoint is counted/varied — `AnalyticsService.init`
/// also fires a session-report POST that these tests aren't measuring, and
/// letting it share this counter made `callCount` (and therefore
/// `responseFactory`'s call-numbered branching) racy depending on whether the
/// session call happened to fire before the dispatch under test.
final class FakeAnalyticsSender: NetworkClient, @unchecked Sendable {
    private var _callCount = 0
    var callCount: Int { _callCount }
    var responseFactory: (Int) -> Int

    init(responseFactory: @escaping (Int) -> Int = { _ in 200 }) {
        self.responseFactory = responseFactory
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        guard request.url.absoluteString == DigiaEndpoints.track else {
            return NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
        }
        _callCount += 1
        let status = responseFactory(_callCount)
        return NetworkResponse(statusCode: status, headers: [:], body: nil, isSuccessful: (200..<300).contains(status))
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
    }

    func openSseStream(request: NetworkRequest, handler: SseStreamHandler) -> CancellableSubscription {
        final class EmptySub: CancellableSubscription { func cancel() {} }
        return EmptySub()
    }
}

/// Fake sender that always throws, to exercise the "ambiguous" (no status code
/// at all — no connectivity, timeout, DNS failure) retry path. Only counts the
/// track-dispatch endpoint, for the same reason as `FakeAnalyticsSender` above.
final class ThrowingAnalyticsSender: NetworkClient, @unchecked Sendable {
    private var _callCount = 0
    var callCount: Int { _callCount }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        guard request.url.absoluteString == DigiaEndpoints.track else {
            return NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
        }
        _callCount += 1
        throw URLError(.notConnectedToInternet)
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        throw URLError(.notConnectedToInternet)
    }

    func openSseStream(request: NetworkRequest, handler: SseStreamHandler) -> CancellableSubscription {
        final class EmptySub: CancellableSubscription { func cancel() {} }
        return EmptySub()
    }
}

// MARK: - Suite

private func sleepMillis(_ ms: UInt64) async throws {
    try await Task.sleep(nanoseconds: ms * 1_000_000)
}

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
        sender: any NetworkClient = FakeAnalyticsSender(),
        defaults: UserDefaults? = nil
    ) -> AnalyticsService {
        let store = defaults ?? UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
        let storage = UserDefaultsLocalStorage(defaults: store)
        let identityManager = IdentityManager(storage: storage.scoped("identity"))
        let sessionManager = SessionManager(storage: storage.scoped("session"), timeoutMs: Int64(config.sessionTimeoutMs), observeLifecycle: false)
        return AnalyticsService(
            config: config,
            apiKey: "test-api-key",
            identityManager: identityManager,
            sessionManager: sessionManager,
            queue: AnalyticsQueue(defaults: store),
            staticContext: ["sdk_version": "1.0.0", "sdk_platform": "ios"],
            networkClient: sender
        )
    }

    private func buildPayload(_ campaignKey: String) -> CEPTriggerPayload {
        CEPTriggerPayload(cepCampaignId: campaignKey, campaignKey: campaignKey, cepMetadata: [:])
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

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

    @Test("presentation_id groups the events of one showing, and is absent when there is none")
    func presentationIdIsStamped() {
        let service = makeService()
        let payload = buildPayload("test")

        service.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"),
            payload: payload,
            campaignId: "c1",
            campaignType: "nudge",
            presentationId: "pres-1"
        )
        service.capture(
            NudgeEvent.Dismissed(),
            payload: payload,
            campaignId: "c1",
            campaignType: "nudge"
        )

        let entries = service.queue.peek(maxCount: 10)
        #expect(entries.count == 2)
        // The key events from one showing are grouped by. `campaign_key` cannot
        // do that job: one campaign can be delivered many times in a session.
        #expect(entries[0].payload["presentation_id"] as? String == "pres-1")
        // Absent, not null, when there is none — a live test, or a surface
        // outliving its presentation.
        #expect(entries[1].payload["presentation_id"] == nil)
    }

    @Test("click analytics preserve action URL")
    func clickAnalyticsPreserveActionURL() {
        let service = makeService()
        let payload = buildPayload("test")
        let urls = [
            "https://digia.tech/nudge",
            "https://digia.tech/guide",
            "medihubrn://carousel-step",
            "medihubrn://carousel",
            "https://digia.tech/story",
        ]

        service.capture(
            NudgeEvent.Clicked(actionType: "url", actionUrl: urls[0]),
            payload: payload)
        service.capture(
            GuideEvent.StepClicked(
                itemIndex: 1, actionType: "url", actionUrl: urls[1]),
            payload: payload)
        service.capture(
            CarouselEvent.StepClicked(
                itemIndex: 1, actionType: "deeplink", actionUrl: urls[2]),
            payload: payload)
        service.capture(
            CarouselEvent.Clicked(actionType: "deeplink", actionUrl: urls[3]),
            payload: payload)
        service.capture(
            StoriesEvent.StepClicked(
                itemIndex: 1, actionType: "url", actionUrl: urls[4]),
            payload: payload)

        for (index, entry) in service.queue.peek(maxCount: 10).enumerated() {
            let properties = entry.payload["properties"] as? [String: Any]
            #expect(properties?["action_type"] != nil)
            #expect(properties?["action_url"] as? String == urls[index])
        }
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
        try await sleepMillis(50)

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
        try await sleepMillis(300)

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
        try await sleepMillis(50)

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
        try await sleepMillis(5)
        #expect(service.retryAttempt == 1)
        #expect(service.queue.size == 1)

        // let the retry fire and succeed
        try await sleepMillis(200)
        #expect(service.queue.size == 0)
        #expect(service.retryAttempt == 0)
        #expect(fakeSender.callCount == 2)
    }

    @Test("new events don't jump ahead of a pending retry")
    func newEventsDeferToPendingRetry() async throws {
        let fakeSender = FakeAnalyticsSender { callNum in callNum == 1 ? 500 : 200 }
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 2),
            sender: fakeSender
        )
        service.retryScheduleMs = [50]  // long enough to add a second event before it fires

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()
        // let the flush attempt run and fail (500); retry is now pending
        try await sleepMillis(5)
        #expect(fakeSender.callCount == 1)

        // This second capture reaches flushBatchSize (2) — without the guard this
        // would dispatch immediately and resend the still-queued failed event early.
        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p2"))
        try await sleepMillis(10)
        #expect(fakeSender.callCount == 1)  // no early dispatch — still just the one attempt
        #expect(service.queue.size == 2)

        // let the originally scheduled retry fire — picks up both events together
        try await sleepMillis(100)
        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 2)
    }

    @Test("4xx/5xx responses retry up to the cap (10) then drop the event")
    func httpErrorRetriesThenDrops() async throws {
        let fakeSender = FakeAnalyticsSender { _ in 400 }
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: fakeSender
        )
        service.retryScheduleMs = [2]  // fast, fixed retries for the test

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()

        for _ in 0..<20 {
            if fakeSender.callCount == 10 { break }
            try await sleepMillis(50)
        }

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 10)
    }

    @Test("transport failures (no status code) retry up to the cap (10) then drop the event")
    func transportFailureRetriesThenDrops() async throws {
        let throwingSender = ThrowingAnalyticsSender()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: throwingSender
        )
        service.retryScheduleMs = [2]  // fast, fixed retries for the test

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()

        for _ in 0..<20 {
            if throwingSender.callCount == 10 { break }
            try await sleepMillis(50)
        }

        #expect(service.queue.size == 0)
        #expect(throwingSender.callCount == 10)
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
        try await sleepMillis(50)

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

        try await sleepMillis(300)
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
        try await sleepMillis(20)

        #expect(service.queue.size == 1)
        #expect(fakeSender.callCount == 0)
    }

    // MARK: - HealthSink envelope

    /// The assertion that "no new ClickHouse column" is actually true: a
    /// `sdk_health` event's top-level shape is byte-for-byte the same set of
    /// keys a normal first-party event's is. Only `event_name` and the
    /// contents of `properties` may differ — everything else (identity,
    /// timestamps, `campaign_key`) comes from the same enqueue path for free.
    @Test("sdk_health rides the existing envelope verbatim — no new top-level columns")
    func healthEventEnvelopeMatchesNormalEvent() {
        let service = makeService()

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("cmp_normal"))
        service.captureHealth(
            campaignKey: "cmp_health",
            reason: "malformed_campaign_skipped",
            stage: "parse",
            detail: nil,
            buildMode: "debug"
        )

        let entries = service.queue.peek(maxCount: 2)
        #expect(entries.count == 2)
        let normalEvent = entries[0].payload
        let healthEvent = entries[1].payload

        // No column exists on the health payload that isn't part of the one
        // envelope every first-party event already uses. `campaign_id` /
        // `campaign_type` / `presentation_id` / `user_id` are optional on
        // both — absent, not null, when there is nothing to put there — so a
        // health event naturally has fewer populated keys than a normal event
        // that happens to resolve a campaign id; the assertion that matters is
        // that the health payload invents nothing new.
        let knownEnvelopeKeys: Set<String> = [
            "event_id", "event_name", "occurred_at", "anonymous_id", "session_id",
            "campaign_id", "campaign_key", "campaign_type", "presentation_id", "user_id",
            "properties",
        ]
        #expect(Set(healthEvent.keys).isSubset(of: knownEnvelopeKeys))
        // And it does carry every column that has no dependency on campaign
        // resolution — the ones a normal event always has too.
        let mandatoryKeys: Set<String> = [
            "event_id", "event_name", "occurred_at", "anonymous_id", "session_id", "properties",
        ]
        #expect(mandatoryKeys.isSubset(of: Set(healthEvent.keys)))
        #expect(mandatoryKeys.isSubset(of: Set(normalEvent.keys)))

        // The only intended differences: the event name, and the presence of
        // campaign_id/campaign_type (health events don't resolve either).
        #expect(healthEvent["event_name"] as? String == "sdk_health")
        #expect(normalEvent["event_name"] as? String != "sdk_health")
        #expect(healthEvent["campaign_id"] == nil)
        #expect(healthEvent["campaign_type"] == nil)
        #expect(healthEvent["campaign_key"] as? String == "cmp_health")

        // Identity and timestamp columns are populated exactly like a normal
        // event's — they come from the same enqueue path.
        #expect((healthEvent["event_id"] as? String)?.isEmpty == false)
        #expect((healthEvent["occurred_at"] as? String)?.isEmpty == false)
        #expect((healthEvent["anonymous_id"] as? String)?.isEmpty == false)
        #expect((healthEvent["session_id"] as? String)?.isEmpty == false)

        let healthProps = healthEvent["properties"] as? [String: Any]
        #expect(healthProps?["reason"] as? String == "malformed_campaign_skipped")
        #expect(healthProps?["stage"] as? String == "parse")
        #expect(healthProps?["detail"] == nil)
        #expect(healthProps?["build_mode"] as? String == "debug")
        // The static context (sdk_version, sdk_platform, …) merges in for a
        // health event exactly as it does for a normal one.
        #expect(healthProps?["sdk_version"] as? String == "1.0.0")
    }

    @Test("captureHealth carries stage and detail only when present")
    func captureHealthOptionalFields() {
        let service = makeService()

        service.captureHealth(
            campaignKey: nil,
            reason: "fetch_failed_auth",
            stage: nil,
            detail: ["http_status": "401"],
            buildMode: "release"
        )

        let entry = service.queue.peek(maxCount: 1)[0].payload
        #expect(entry["campaign_key"] == nil)
        let props = entry["properties"] as? [String: Any]
        #expect(props?["stage"] == nil)
        #expect((props?["detail"] as? [String: String]) == ["http_status": "401"])
    }

    @Test("captureHealth is a no-op when analytics is disabled")
    func captureHealthNoOpWhenDisabled() {
        let service = makeService(config: AnalyticsConfig(enabled: false))
        service.captureHealth(
            campaignKey: "cmp", reason: "fetch_failed_auth", stage: nil, detail: nil, buildMode: "release")
        #expect(service.queue.size == 0)
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
        try await sleepMillis(50)

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 1)
    }
}
