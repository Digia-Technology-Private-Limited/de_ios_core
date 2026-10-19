import Foundation
import Testing
@testable import DigiaEngage

/// Records each `track` body the two queues send.
private final class RecordingSender: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: Any]] = []

    var requests: [[String: Any]] { lock.withLock { stored } }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        if request.url.absoluteString == DigiaEndpoints.track,
           let body = request.body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            lock.withLock { stored.append(json) }
        }
        return NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
    }

    func openSseStream(request: NetworkRequest, handler: SseStreamHandler) -> CancellableSubscription {
        final class EmptySub: CancellableSubscription { func cancel() {} }
        return EmptySub()
    }
}

/// Collects the reason of every record that carries one.
private final class ReasonSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var reasons: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func accepts(_ record: TimelineRecord) -> Bool { true }

    func emit(_ record: TimelineRecord) {
        guard let reason = record.reason?.wire else { return }
        lock.lock()
        stored.append(reason)
        lock.unlock()
    }
}

/// Flutter: `test/app_event_queue_test.dart`.
@MainActor
@Suite("App event queue", .serialized)
struct DMCAppEventQueueTests {
    private let sender = RecordingSender()

    private struct Rig {
        let experience: AnalyticsService
        let appEvents: AnalyticsService
        let service: AppEventsService
    }

    private func start(config: AnalyticsConfig? = nil, appQueueMax: Int = appEventQueueMaxEvents) -> Rig {
        let config = config ?? AnalyticsConfig(flushIntervalMs: 100_000, flushBatchSize: 100, maxBatchSize: 100)
        let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)
        let identity = IdentityManager(storage: storage.scoped("identity"))
        let session = SessionManager(
            storage: storage.scoped("session"), timeoutMs: Int64(config.sessionTimeoutMs), observeLifecycle: false
        )
        func make(_ key: String, max: Int?) -> AnalyticsService {
            AnalyticsService(
                config: config,
                identityManager: identity,
                sessionManager: session,
                queue: AnalyticsQueue(storage: storage.scoped("analytics"), key: key),
                staticContext: [:],
                networkClient: sender,
                maxQueueEvents: max
            )
        }
        let experience = make("queue", max: nil)
        let appEvents = make("app_event_queue", max: appQueueMax)
        return Rig(experience: experience, appEvents: appEvents, service: AppEventsService(appEvents))
    }

    private func payload(_ key: String) -> CEPTriggerPayload {
        CEPTriggerPayload(cepCampaignId: "example-campaign", campaignKey: key, cepMetadata: [:])
    }

    private func names(_ service: AnalyticsService) -> [String?] {
        service.queue.peek(maxCount: 100).map { $0.payload["event_name"] as? String }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test("app events and experience events use separate queues")
    func separateQueues() {
        let rig = start()

        rig.service.track("add_to_cart", properties: ["sku": "PCM-500"])
        rig.experience.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"), payload: payload("c1"),
            campaignId: "id", campaignType: "guide"
        )

        #expect(rig.appEvents.queue.size == 1)
        #expect(rig.experience.queue.size == 1)

        let entry = rig.appEvents.queue.peek(maxCount: 1)[0].payload
        #expect(entry["event_name"] as? String == "add_to_cart")
        // The value/currency pair is gone from the app-event contract.
        #expect(entry["value"] == nil)
        #expect(entry["currency"] == nil)
        #expect(names(rig.experience) == ["Digia Experience Viewed"])
    }

    @Test("each queue flushes only its own events")
    func flushesOwnEvents() async throws {
        let rig = start()
        rig.experience.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"), payload: payload("c1"),
            campaignId: "id", campaignType: "guide"
        )
        rig.service.track("add_to_cart")

        rig.experience.flush()
        try await waitUntil { rig.experience.queue.size == 0 }

        // Independent queues: the experience flush leaves the app-event queue untouched.
        #expect(sender.requests.count == 1)
        #expect(sender.requests[0]["appEvents"] == nil)
        #expect(rig.appEvents.queue.size == 1)

        rig.service.flush()
        try await waitUntil { rig.appEvents.queue.size == 0 }

        let appBody = sender.requests.first { $0["appEvents"] != nil }
        let sent = (appBody?["appEvents"] as? [[String: Any]])?.first
        #expect(sent?["event_name"] as? String == "add_to_cart")
        #expect(sent?["_digia_app_event"] == nil)
    }

    @Test("an app event an older build left in the experience queue still sends")
    func legacyMarkedEventStillSends() {
        let entry = QueueEntry(
            eventId: "legacy-1",
            payload: ["event_id": "legacy-1", "event_name": "legacy_view", "_digia_app_event": true],
            createdAt: 0,
            attempts: 0
        )
        let body = AnalyticsService.trackBody([entry])

        #expect((body["events"] as? [Any])?.isEmpty == true)
        let appEvents = body["appEvents"] as? [[String: Any]]
        #expect(appEvents?.first?["event_name"] as? String == "legacy_view")
        #expect(appEvents?.first?["_digia_app_event"] == nil)
    }

    @Test("each queue drops its own oldest at its own cap")
    func ownCaps() {
        let rig = start(
            config: AnalyticsConfig(flushIntervalMs: 100_000, flushBatchSize: 100, queueMaxEvents: 3),
            appQueueMax: 2
        )

        for i in 0..<4 { rig.service.track("app-\(i)") }
        for i in 0..<5 {
            rig.experience.capture(
                NudgeEvent.Viewed(displayStyle: "dialog"), payload: payload("exp-\(i)"),
                campaignId: "id", campaignType: "guide"
            )
        }

        #expect(rig.appEvents.queue.size == 2)
        #expect(rig.experience.queue.size == 3)
        #expect(names(rig.appEvents) == ["app-2", "app-3"])
    }

    @Test("the upload switch keeps events out of the app-event queue")
    func uploadSwitchKeepsQueueEmpty() {
        let rig = start()
        rig.service.applyPolicy(AppEventUploadPolicy(enabled: false))

        rig.service.track("add_to_cart")

        #expect(rig.appEvents.queue.size == 0)
    }

    @Test("each app-event drop reports one reason, and upload-off stays silent")
    func dropReasons() {
        let rig = start(appQueueMax: 2)
        let sink = ReasonSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }

        // Rate: one token in hand, then the bucket is empty.
        rig.service.applyPolicy(AppEventUploadPolicy(enabled: true, ratePerMinute: 1, burst: 1))
        for i in 0..<4 { rig.service.track("rate-\(i)") }

        // Blocked: the name is on the blocklist, checked before the rate.
        rig.service.applyPolicy(AppEventUploadPolicy(blockedNames: ["scroll_view"]))
        rig.service.track("scroll_view")

        // Queue-full: five events into a two-slot queue that already holds one.
        for name in ["a", "b", "c", "d", "e"] { rig.service.track(name) }

        let reasons = sink.reasons.filter { $0.hasPrefix("app_event_") }
        #expect(Array(NSOrderedSet(array: reasons)) as? [String] == [
            "app_event_rate_limited", "app_event_blocked", "app_event_queue_full",
        ])

        // Upload off is configured behaviour: silent, even though it drops every event.
        let before = sink.reasons.count
        rig.service.applyPolicy(AppEventUploadPolicy(enabled: false))
        rig.service.track("msg")
        #expect(sink.reasons.count == before)
    }
}
