import Foundation
import Testing
import UIKit

@testable import DigiaEngage

// Campaign id/type are resolved from the campaign store at event time and passed
// into capture() by the caller; this helper supplies fixed test values so the
// existing call sites stay terse.
@MainActor
extension AnalyticsService {
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
    /// When each track call arrived, so a test can assert the gap between sends instead of racing
    /// a wall-clock window on a main actor that other suites keep busy.
    private(set) var callTimes: [ContinuousClock.Instant] = []
    var responseFactory: (Int) -> Int
    /// How long a track call takes to answer — lets a test capture while a send is in flight.
    var responseDelayMs: UInt64 = 0
    /// While true, a track call does not answer — holds a send in flight.
    var holdsResponses = false
    /// The events of each track body, in send order.
    private(set) var batches: [[[String: Any]]] = []
    var batchSizes: [Int] { batches.map(\.count) }

    init(responseFactory: @escaping (Int) -> Int = { _ in 200 }) {
        self.responseFactory = responseFactory
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        guard request.url.absoluteString == DigiaEndpoints.track else {
            return NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
        }
        callTimes.append(.now)
        _callCount += 1
        if let body = request.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let events = json["events"] as? [[String: Any]]
        {
            batches.append(events)
        }
        let status = responseFactory(_callCount)
        if responseDelayMs > 0 { try await Task.sleep(nanoseconds: responseDelayMs * 1_000_000) }
        while holdsResponses { try await Task.sleep(nanoseconds: 5_000_000) }
        return NetworkResponse(
            statusCode: status, headers: [:], body: nil, isSuccessful: (200..<300).contains(status))
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
    }

    func openSseStream(request: NetworkRequest, handler: SseStreamHandler)
        -> CancellableSubscription
    {
        final class EmptySub: CancellableSubscription { func cancel() {} }
        return EmptySub()
    }
}

/// Fake sender that always throws, to exercise the "ambiguous" (no status code
/// at all — no connectivity, timeout, DNS failure) retry path. Only counts the
/// track-dispatch endpoint, for the same reason as `FakeAnalyticsSender` above.
/// Throws for its first `failures` track sends — no HTTP response at all — then succeeds.
final class ThrowingAnalyticsSender: NetworkClient, @unchecked Sendable {
    private var _callCount = 0
    var callCount: Int { _callCount }
    private let failures: Int

    init(failures: Int = .max) {
        self.failures = failures
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        guard request.url.absoluteString == DigiaEndpoints.track else {
            return NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
        }
        _callCount += 1
        if _callCount <= failures { throw URLError(.notConnectedToInternet) }
        return NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        throw URLError(.notConnectedToInternet)
    }

    func openSseStream(request: NetworkRequest, handler: SseStreamHandler)
        -> CancellableSubscription
    {
        final class EmptySub: CancellableSubscription { func cancel() {} }
        return EmptySub()
    }
}

/// Background time the test controls: records begins and ends, expires on demand.
@MainActor
final class FakeBackgroundTime: BackgroundTimeProvider {
    private(set) var begun = 0
    private(set) var ended: [Int] = []
    private var expiration: (@MainActor () -> Void)?

    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        begun += 1
        self.expiration = expiration
        return begun
    }

    func end(_ id: Int) { ended.append(id) }

    func expire() { expiration?() }
}

/// A network whose state the test sets; changes reach the service like the OS's.
final class FakeNetworkMonitor: NetworkMonitor, @unchecked Sendable {
    private(set) var isOnline: Bool
    private var onChange: (@Sendable (Bool) -> Void)?

    init(online: Bool) {
        isOnline = online
    }

    func start(_ onChange: @escaping @Sendable (Bool) -> Void) { self.onChange = onChange }
    func stop() { onChange = nil }

    func set(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}

// MARK: - Shared helpers

/// A service over a memory queue and fresh storage. Shared with
/// `AnalyticsServiceIOSTests` and `AnalyticsServiceSQLiteTests`.
@MainActor
func makeTestAnalyticsService(
    config: AnalyticsConfig = AnalyticsConfig(flushIntervalMs: 10_000),
    sender: any NetworkClient = FakeAnalyticsSender(),
    defaults: UserDefaults? = nil,
    queue: (any AnalyticsQueueProtocol)? = nil,
    networkMonitor: any NetworkMonitor = AlwaysOnlineNetworkMonitor(),
    backgroundTime: BackgroundTimeProvider = FakeBackgroundTime()
) -> AnalyticsService {
    let store = defaults ?? UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
    let storage = UserDefaultsLocalStorage(defaults: store)
    let identityManager = IdentityManager(storage: storage.scoped("identity"))
    let sessionManager = SessionManager(
        storage: storage.scoped("session"), timeoutMs: Int64(config.sessionTimeoutMs),
        observeLifecycle: false)
    return AnalyticsService(
        config: config,
        identityManager: identityManager,
        sessionManager: sessionManager,
        queue: queue ?? MemoryAnalyticsQueue(),
        staticContext: ["sdk_version": "1.0.0", "sdk_platform": "ios"],
        networkClient: sender,
        networkMonitor: networkMonitor,
        backgroundTime: backgroundTime
    )
}

func testPayload(_ campaignKey: String) -> CEPTriggerPayload {
    CEPTriggerPayload(cepCampaignId: campaignKey, campaignKey: campaignKey, cepMetadata: [:])
}

/// Polls `condition` (up to 8 s) instead of guessing how long the work takes:
/// the main actor is shared with other suites and can be busy for a while.
@MainActor
func waitForAnalytics(_ condition: () -> Bool) async throws {
    for _ in 0..<800 where !condition() {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// An event whose properties hold Foundation's mutable containers, which a
/// caller can change after `capture` returns.
struct MutablePropertiesEvent: EngageAnalyticsEvent {
    let eventName = "Digia Experience Viewed"
    let properties: [String: Any]
}

// MARK: - Suite

private func sleepMillis(_ ms: UInt64) async throws {
    try await Task.sleep(nanoseconds: ms * 1_000_000)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    try await waitForAnalytics(condition)
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
        defaults: UserDefaults? = nil,
        queue: (any AnalyticsQueueProtocol)? = nil,
        networkMonitor: any NetworkMonitor = AlwaysOnlineNetworkMonitor()
    ) -> AnalyticsService {
        makeTestAnalyticsService(
            config: config, sender: sender, defaults: defaults, queue: queue,
            networkMonitor: networkMonitor)
    }

    private func buildPayload(_ campaignKey: String) -> CEPTriggerPayload {
        testPayload(campaignKey)
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    @Test("queue drops oldest events when capacity is exceeded")
    func queueDropsOldestWhenFull() async {
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 100, queueMaxEvents: 3)
        )

        for i in 0..<5 {
            service.capture(
                NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("event-\(i)"))
        }

        #expect(service.queue.size == 3)
        let entries = await service.queue.peek(maxCount: 10)
        // oldest two dropped; event-2, event-3, event-4 remain
        #expect(entries[0].payload["campaign_key"] as? String == "event-2")
        #expect(entries[1].payload["campaign_key"] as? String == "event-3")
        #expect(entries[2].payload["campaign_key"] as? String == "event-4")
    }

    @Test("event payload has correct structure and identity fields")
    func eventPayloadStructure() async {
        let service = makeService()
        service.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("payload-1"))

        let entries = await service.queue.peek(maxCount: 1)
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
        #expect(event["user_id"] == nil)  // not set — must be absent

        let props = event["properties"] as? [String: Any]
        #expect(props != nil)
        #expect(props?["sdk_version"] as? String == "1.0.0")
        #expect(props?["sdk_platform"] as? String == "ios")
    }

    @Test("event names map correctly for all experience event types")
    func eventNameMapping() async {
        let service = makeService()
        let payload = buildPayload("test")

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: payload)
        service.capture(NudgeEvent.Clicked(elementId: "cta-btn"), payload: payload)
        service.capture(NudgeEvent.Dismissed(), payload: payload)

        let entries = await service.queue.peek(maxCount: 10)
        #expect(entries.count == 3)
        #expect(entries[0].payload["event_name"] as? String == "Digia Experience Viewed")
        #expect(entries[1].payload["event_name"] as? String == "Digia Experience Clicked")
        #expect(entries[2].payload["event_name"] as? String == "Digia Experience Dismissed")

        // element_id is a hoisted top-level column, present only for Clicked.
        #expect(entries[1].payload["element_id"] as? String == "cta-btn")
        #expect(entries[0].payload["element_id"] == nil)
    }

    @Test("impression_id groups the events of one showing, and is absent when there is none")
    func impressionIdIsStamped() async {
        let service = makeService()
        let payload = buildPayload("test")

        service.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"),
            payload: payload,
            campaignId: "c1",
            campaignType: "nudge",
            impressionId: "imp-1"
        )
        service.capture(
            NudgeEvent.Dismissed(),
            payload: payload,
            campaignId: "c1",
            campaignType: "nudge"
        )

        let entries = await service.queue.peek(maxCount: 10)
        #expect(entries.count == 2)
        // The key events from one showing are grouped by. `campaign_key` cannot
        // do that job: one campaign can be delivered many times in a session.
        #expect(entries[0].payload["impression_id"] as? String == "imp-1")
        // Absent, not null, when there is none — a live test, or a surface
        // outliving its presentation.
        #expect(entries[1].payload["impression_id"] == nil)
    }

    @Test("click analytics preserve action url")
    func clickAnalyticsPreserveActionURL() async {
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

        for (index, entry) in await service.queue.peek(maxCount: 10).enumerated() {
            let properties = entry.payload["properties"] as? [String: Any]
            #expect(properties?["action_type"] != nil)
            #expect(properties?["action_url"] as? String == urls[index])
        }
    }

    @Test("capture makes a deep copy of properties")
    func captureDeepCopiesProperties() async {
        let service = makeService()
        let nested = NSMutableDictionary(dictionary: ["key": "original"])
        let properties = NSMutableDictionary(dictionary: ["prop": "initial", "deep": nested])

        service.capture(
            MutablePropertiesEvent(properties: properties as! [String: Any]),
            payload: buildPayload("copy")
        )
        properties["prop"] = "mutated"
        nested["key"] = "mutated"

        let queued =
            await service.queue.peek(maxCount: 1).first?.payload["properties"] as? [String: Any]
        #expect(queued?["prop"] as? String == "initial")
        #expect((queued?["deep"] as? [String: Any])?["key"] as? String == "original")
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
        // The second capture reaches flushBatchSize and enqueues the dispatch Task.
        try await waitUntil { fakeSender.callCount == 1 && service.queue.size == 0 }

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
        try await waitUntil { fakeSender.callCount == 1 && service.queue.size == 0 }

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 1)
    }

    // ── Follow-up flushes ─────────────────────────────────────────────────────

    @Test("events left over after a partial send are flushed on the next interval")
    func leftoverAfterPartialSendFlushesOnInterval() async throws {
        let fakeSender = FakeAnalyticsSender()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 400, flushBatchSize: 3, maxBatchSize: 2),
            sender: fakeSender
        )

        for i in 0..<3 {
            service.capture(
                NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p\(i)"))
        }
        // One batch of 2 goes out at once; one event is left behind.
        try await waitUntil { fakeSender.callCount == 1 && service.queue.size == 1 }
        #expect(fakeSender.callCount == 1)

        try await waitUntil { fakeSender.callCount == 2 && service.queue.size == 0 }
        #expect(fakeSender.callCount == 2)
        // A stalled main actor only delays the timer, so the gap can only grow under load.
        let times = fakeSender.callTimes
        try #require(times.count == 2)
        #expect(
            times[1] - times[0] >= .milliseconds(380), "not before the configured interval (400 ms)"
        )
    }

    @Test("the follow-up flush waits the flush interval whatever the batch size")
    func followUpWaitsTheIntervalWhateverTheBatchSize() async throws {
        let fakeSender = FakeAnalyticsSender()
        fakeSender.holdsResponses = true
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 500, flushBatchSize: 1),
            sender: fakeSender
        )

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("first"))
        try await waitUntil { fakeSender.callCount == 1 }  // send #1 is in flight, and held there
        // This capture's own dispatch is skipped ("already dispatching") and arms no timer.
        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("second"))

        let releasedAt = ContinuousClock.now
        fakeSender.holdsResponses = false  // #1 finishes; the follow-up timer starts from here

        try await waitUntil { fakeSender.callCount == 2 }
        #expect(fakeSender.callCount == 2)
        // A stalled main actor only delays the timer, so the gap can only grow under load; a
        // follow-up fired without waiting would show a gap of a few milliseconds.
        let times = fakeSender.callTimes
        try #require(times.count == 2)
        #expect(
            times[1] - releasedAt >= .milliseconds(480),
            "batch size 1 does not shorten the interval (500 ms)")
    }

    @Test("an event captured during a send waits for the interval instead of being stranded")
    func eventCapturedDuringSendWaitsForInterval() async throws {
        let sender = FakeAnalyticsSender()
        sender.responseDelayMs = 150
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 500, flushBatchSize: 10),
            sender: sender
        )

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("first"))
        service.flush()
        try await waitUntil { sender.callCount == 1 }  // send #1 is in flight
        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("second"))

        try await waitUntil { service.queue.size == 1 && sender.callCount == 1 }  // #1 finished
        try await sleepMillis(200)
        #expect(sender.callCount == 1, "not before the interval")

        try await waitUntil { sender.callCount == 2 && service.queue.size == 0 }
        #expect(service.queue.size == 0)
    }

    @Test("after a failed send only the retry fires, not also a flush timer")
    func afterFailureOnlyTheRetryFires() async throws {
        let fakeSender = FakeAnalyticsSender { callNum in callNum == 1 ? 500 : 200 }
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 100, flushBatchSize: 10),
            sender: fakeSender
        )
        service.retryScheduleMs = [1_000]

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()
        try await waitUntil { service.retryAttempt == 1 }
        #expect(fakeSender.callCount == 1)

        try await waitUntil { fakeSender.callCount == 2 && service.queue.size == 0 }
        #expect(fakeSender.callCount == 2)
        // A second timer at the 100 ms flush interval would have resent long before the 1 s retry.
        // A stalled main actor only delays the resend, so the gap can only grow under load.
        let times = fakeSender.callTimes
        try #require(times.count == 2)
        #expect(times[1] - times[0] >= .milliseconds(980), "only the retry may resend (1000 ms)")
    }

    // ── Test Kit mode ─────────────────────────────────────────────────────────

    @Test(
        "test kit mode sends each event at once while normal mode batches by the default interval")
    func testKitModeSendsAtOnce() async throws {
        func services(_ client: MockNetworkClient) -> SDKServices {
            let storage = UserDefaultsLocalStorage(
                defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)
            return SDKServices(
                config: DigiaConfig(apiKey: "test_key"), storage: storage, networkClient: client,
                analyticsQueue: MemoryAnalyticsQueue())
        }
        func trackPosts(_ client: MockNetworkClient) -> Int {
            client.recordedRequests.filter { $0.url.absoluteString == DigiaEndpoints.track }.count
        }

        // Normal mode: the default 30 s interval holds a lone event.
        DigiaEndpoints.resetForTest()
        let normalClient = MockNetworkClient()
        let normal = services(normalClient)
        normal.analyticsService?.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("n1"), campaignId: "c",
            campaignType: "nudge")
        try await sleepMillis(300)
        #expect(trackPosts(normalClient) == 0)
        normal.analyticsService?.clear()

        // Test Kit mode: the same default config sends it immediately.
        DigiaEndpoints.resetForTest()
        try DigiaEndpoints.setTestRoot("http://127.0.0.1:9")
        defer { DigiaEndpoints.resetForTest() }
        let testClient = MockNetworkClient()
        let testMode = services(testClient)
        testMode.analyticsService?.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("t1"), campaignId: "c",
            campaignType: "nudge")
        try await waitUntil { trackPosts(testClient) == 1 }
        #expect(trackPosts(testClient) == 1)
        testMode.analyticsService?.clear()
    }

    @Test("explicit flush dispatches pending events")
    func explicitFlushDispatchesPending() async throws {
        let fakeSender = FakeAnalyticsSender()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: fakeSender
        )

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        #expect(service.queue.size == 1)

        service.flush()
        try await waitUntil { fakeSender.callCount == 1 && service.queue.size == 0 }

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 1)
    }

    @Test("maxBatchSize is clamped to 1 to 200")
    func maxBatchSizeIsClamped() async throws {
        let sender = FakeAnalyticsSender()
        let wide = makeService(
            config: AnalyticsConfig(
                flushIntervalMs: 10_000, flushBatchSize: 100_000, maxBatchSize: 500),
            sender: sender
        )
        for i in 0...AnalyticsConfig.maxBatchSizeLimit {
            wide.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p\(i)"))
        }
        wide.flush()
        try await waitUntil { sender.callCount == 1 && wide.queue.size == 1 }
        #expect(
            sender.batchSizes == [AnalyticsConfig.maxBatchSizeLimit], "one capped batch per send")
        wide.clear()

        let zeroSender = FakeAnalyticsSender()
        let zero = makeService(
            config: AnalyticsConfig(
                flushIntervalMs: 10_000, flushBatchSize: 100_000, maxBatchSize: 0),
            sender: zeroSender
        )
        zero.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("z"))
        zero.flush()
        try await waitUntil { zeroSender.callCount == 1 && zero.queue.size == 0 }
        #expect(zeroSender.batchSizes == [1], "a zero batch size still sends")
    }

    @Test("5xx response retries and event survives until success")
    func fiveXxRetrySucceeds() async throws {
        let fakeSender = FakeAnalyticsSender { callNum in callNum == 1 ? 500 : 200 }
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: fakeSender
        )
        // Long enough that the first attempt's outcome is observed before the
        // retry fires, whatever else the main actor is doing.
        service.retryScheduleMs = [1_000]

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()
        // The first attempt fails (500); the event waits for the retry.
        try await waitUntil { service.retryAttempt == 1 }
        #expect(service.retryAttempt == 1)
        #expect(service.queue.size == 1)

        // The retry fires and succeeds.
        try await waitUntil {
            fakeSender.callCount == 2 && service.queue.size == 0 && service.retryAttempt == 0
        }
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
        // Long enough to add a second event before it fires, whatever else the main actor is doing.
        service.retryScheduleMs = [1_000]

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()
        // The flush attempt fails (500); the retry is now pending.
        try await waitUntil { service.retryAttempt == 1 }
        #expect(fakeSender.callCount == 1)

        // This second capture reaches flushBatchSize (2) — without the guard this
        // would dispatch immediately and resend the still-queued failed event early.
        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p2"))
        try await sleepMillis(10)
        #expect(fakeSender.callCount == 1)  // no early dispatch — still just the one attempt
        #expect(service.queue.size == 2)

        // The originally scheduled retry fires and picks up both events together.
        try await waitUntil { fakeSender.callCount == 2 && service.queue.size == 0 }
        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 2)
    }

    @Test("4xx-5xx responses retry up to the cap then drop the event")
    func httpErrorRetriesThenDrops() async throws {
        let fakeSender = FakeAnalyticsSender { _ in 400 }
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: fakeSender
        )
        service.retryScheduleMs = [2]  // fast, fixed retries for the test

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()

        try await waitUntil { fakeSender.callCount == 10 && service.queue.size == 0 }

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 10)
    }

    @Test("transport failures are retried without counting attempts and never drop the event")
    func transportFailuresAreNotCounted() async throws {
        // More failures than the cap of 10: a server failure would have dropped it.
        let sender = ThrowingAnalyticsSender(failures: 15)
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: sender
        )
        service.retryScheduleMs = [2]

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()

        try await waitUntil { sender.callCount >= 12 }
        #expect(service.queue.size == 1)
        #expect(await service.queue.peek(maxCount: 1).first?.attempts == 0)

        try await waitUntil { sender.callCount == 16 && service.queue.size == 0 }
        #expect(service.queue.size == 0)
    }

    @Test("offline pauses sending and the network's return sends at once")
    func offlinePausesAndReconnectSends() async throws {
        let network = FakeNetworkMonitor(online: false)
        let sender = FakeAnalyticsSender()
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 1),
            sender: sender,
            networkMonitor: network
        )

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sender.callCount == 0, "nothing is attempted offline")
        #expect(service.queue.size == 1)

        network.set(true)
        try await waitUntil { sender.callCount == 1 && service.queue.size == 0 }
        #expect(service.queue.size == 0)
    }

    @Test("a network change does not cut short a server failure's backoff")
    func networkChangeKeepsServerBackoff() async throws {
        let network = FakeNetworkMonitor(online: true)
        let sender = FakeAnalyticsSender { _ in 500 }
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: sender,
            networkMonitor: network
        )
        service.retryScheduleMs = [60_000]

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.flush()
        try await waitUntil { sender.callCount == 1 && service.retryAttempt == 1 }

        network.set(false)
        network.set(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sender.callCount == 1, "the retry keeps its backoff")
        #expect(await service.queue.peek(maxCount: 1).first?.attempts == 1)
        service.clear()
    }

    @Test("going to the background flushes pending events")
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
        try await waitUntil { fakeSender.callCount == 1 && service.queue.size == 0 }

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 1)
    }

    @Test("persisted queue flushes on next cold init")
    func persistedQueueFlushesOnColdInit() async throws {
        let (defaults, suiteName) = makeDefaults()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics_\(UUID().uuidString).db").path
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        func sqliteQueue() -> SQLiteAnalyticsQueue {
            SQLiteAnalyticsQueue(opener: AnalyticsDatabaseOpener(resolvePath: { path }))
        }

        // First process — enqueue into SQLite, then die.
        let queue1 = sqliteQueue()
        let service1 = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            defaults: defaults,
            queue: queue1
        )
        service1.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("persisted"))
        #expect(service1.queue.size == 1)
        service1.clear()
        await queue1.close()

        // Second process — same file, short timer: the stored event is sent.
        let fakeSender = FakeAnalyticsSender()
        let queue2 = sqliteQueue()
        let service2 = makeService(
            config: AnalyticsConfig(flushIntervalMs: 50, flushBatchSize: 10),
            sender: fakeSender,
            defaults: defaults,
            queue: queue2
        )

        try await waitUntil { fakeSender.callCount == 1 && service2.queue.size == 0 }

        #expect(fakeSender.callCount == 1)
        #expect(await queue2.count() == 0)
        await queue2.close()
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
    @Test("a health event is the first-party envelope, with health only inside properties")
    func healthEventEnvelopeMatchesNormalEvent() async {
        let service = makeService()

        service.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("cmp_normal"))
        service.captureHealth(
            campaignKey: "cmp_health",
            reason: "malformed_campaign_skipped",
            stage: "parse",
            detail: nil,
            buildMode: "debug"
        )

        let entries = await service.queue.peek(maxCount: 2)
        #expect(entries.count == 2)
        let normalEvent = entries[0].payload
        let healthEvent = entries[1].payload

        // No column exists on the health payload that isn't part of the one
        // envelope every first-party event already uses. `campaign_id` /
        // `campaign_type` / `impression_id` / `user_id` are optional on
        // both — absent, not null, when there is nothing to put there — so a
        // health event naturally has fewer populated keys than a normal event
        // that happens to resolve a campaign id; the assertion that matters is
        // that the health payload invents nothing new.
        let knownEnvelopeKeys: Set<String> = [
            "event_id", "event_name", "occurred_at", "anonymous_id", "session_id",
            "campaign_id", "campaign_key", "campaign_type", "impression_id", "user_id",
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

    @Test("disabled analytics drops a health event rather than throwing")
    func captureHealthNoOpWhenDisabled() {
        let service = makeService(config: AnalyticsConfig(enabled: false))
        service.captureHealth(
            campaignKey: "cmp", reason: "fetch_failed_auth", stage: nil, detail: nil,
            buildMode: "release")
        #expect(service.queue.size == 0)
    }

    @Test("partial failure removes all batched events without retry")
    func partialFailureRemovesAllEvents() async throws {
        let fakeSender = FakeAnalyticsSender { _ in 207 }
        let service = makeService(
            config: AnalyticsConfig(flushIntervalMs: 10_000, flushBatchSize: 10),
            sender: fakeSender
        )

        service.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: buildPayload("p1"))
        service.capture(NudgeEvent.Clicked(elementId: "cta"), payload: buildPayload("p2"))

        service.flush()
        try await waitUntil { fakeSender.callCount == 1 && service.queue.size == 0 }

        #expect(service.queue.size == 0)
        #expect(fakeSender.callCount == 1)
    }
}
