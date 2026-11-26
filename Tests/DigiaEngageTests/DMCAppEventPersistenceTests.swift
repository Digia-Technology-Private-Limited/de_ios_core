import Foundation
import Testing
@testable import DigiaEngage

/// Records the app-event names and Digia event names of each `track` body, and
/// fails the request while `online` is false.
private final class PersistenceSender: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _online = false
    private var _appEventNames: [String] = []
    private var _eventNames: [String] = []

    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }
    var appEventNames: [String] { lock.withLock { _appEventNames } }
    var eventNames: [String] { lock.withLock { _eventNames } }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        guard request.url.absoluteString == DigiaEndpoints.track else {
            return NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
        }
        guard online else { throw URLError(.notConnectedToInternet) }
        if let body = request.body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            lock.withLock {
                _appEventNames += (json["appEvents"] as? [[String: Any]] ?? []).compactMap { $0["event_name"] as? String }
                _eventNames += (json["events"] as? [[String: Any]] ?? []).compactMap { $0["event_name"] as? String }
            }
        }
        return NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
    }

    func executeCapped(request: NetworkRequest, maxBytes: Int) async throws -> NetworkResponse {
        let response = try await execute(request: request)
        guard let body = response.body, body.count > maxBytes else { return response }
        return NetworkResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: Data(body.prefix(maxBytes + 1)),
            isSuccessful: response.isSuccessful)
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
    var reasons: [String] { lock.withLock { stored } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) {
        guard let reason = record.reason?.wire else { return }
        lock.withLock { stored.append(reason) }
    }
}

/// Host-app events across a process kill, over the real SQLite queue. Same
/// cases on Flutter and Android.
@MainActor
@Suite("App event persistence", .serialized)
struct DMCAppEventPersistenceTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("app_events_\(UUID().uuidString)", isDirectory: true)
    private let defaults = UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!

    private var appEventsPath: String {
        directory.appendingPathComponent(AnalyticsDatabaseOpener.appEventsFileName).path
    }
    private var analyticsPath: String {
        directory.appendingPathComponent(AnalyticsDatabaseOpener.fileName).path
    }

    /// One "process" on the shared storage directory.
    @MainActor private struct Launch {
        let appEvents: AppEventsService
        let appEventService: AnalyticsService
        let appEventQueue: SQLiteAnalyticsQueue
        let experience: AnalyticsService
        let experienceQueue: SQLiteAnalyticsQueue

        /// The kill: stop the services and close both database files.
        func kill() async {
            appEvents.clear()
            experience.clear()
            await appEventQueue.close()
            await experienceQueue.close()
        }
    }

    private func launch(_ sender: PersistenceSender) throws -> Launch {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = AnalyticsConfig(flushIntervalMs: 600_000, flushBatchSize: 100_000, maxBatchSize: 2_500)
        let appPath = appEventsPath
        let expPath = analyticsPath
        let appQueue = SQLiteAnalyticsQueue(
            opener: AnalyticsDatabaseOpener(resolvePath: { appPath }), maxEvents: appEventQueueMaxEvents
        )
        let expQueue = SQLiteAnalyticsQueue(opener: AnalyticsDatabaseOpener(resolvePath: { expPath }))
        let storage = UserDefaultsLocalStorage(defaults: defaults)
        let appService = AnalyticsService(
            config: config,
            identityManager: IdentityManager(storage: storage.scoped("identity")),
            sessionManager: SessionManager(
                storage: storage.scoped("session"), timeoutMs: Int64(config.sessionTimeoutMs), observeLifecycle: false
            ),
            queue: appQueue,
            staticContext: [:],
            networkClient: sender,
            maxQueueEvents: appEventQueueMaxEvents
        )
        appService.retryScheduleMs = [600_000]
        let experience = makeTestAnalyticsService(config: config, sender: sender, defaults: defaults, queue: expQueue)
        experience.retryScheduleMs = [600_000]
        return Launch(
            appEvents: AppEventsService(appService), appEventService: appService, appEventQueue: appQueue,
            experience: experience, experienceQueue: expQueue
        )
    }

    /// Flushes until both queues are empty (a flush sends one batch of at most 200).
    private func flushAll(_ launch: Launch) async throws {
        for _ in 0..<800 {
            let appCount = await launch.appEventQueue.count()
            let remaining = appCount + (await launch.experienceQueue.count())
            if remaining == 0 { break }
            launch.appEvents.flush()
            launch.experience.flush()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Let an in-flight response settle before the caller asserts on it.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func wipe() {
        try? FileManager.default.removeItem(at: directory)
    }

    // dmc-case: dmc.app_event.survives_kill
    @Test("events tracked offline survive a kill and upload once, in order")
    func survivesKill() async throws {
        defer { wipe() }
        let sender = PersistenceSender()
        let first = try launch(sender)
        for name in ["a", "b", "c"] { first.appEvents.track(name) }
        await first.kill()

        let second = try launch(sender)
        sender.online = true
        try await flushAll(second)

        #expect(sender.appEventNames == ["a", "b", "c"])
        await second.kill()
    }

    // dmc-case: dmc.app_event.no_resend_after_flush
    @Test("an event already uploaded is not sent again after a kill")
    func noResendAfterFlush() async throws {
        defer { wipe() }
        let sender = PersistenceSender()
        sender.online = true
        let first = try launch(sender)
        first.appEvents.track("a")
        try await flushAll(first)
        #expect(sender.appEventNames == ["a"])
        await first.kill()

        let second = try launch(sender)
        try await flushAll(second)

        #expect(sender.appEventNames == ["a"])
        await second.kill()
    }

    // dmc-case: dmc.app_event.own_file_own_queue
    @Test("app events and impressions live in separate files, and losing one leaves the other")
    func ownFileOwnQueue() async throws {
        defer { wipe() }
        let sender = PersistenceSender()
        let first = try launch(sender)
        first.appEvents.track("add_to_cart")
        first.experience.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"), payload: testPayload("c1"),
            campaignId: "id", campaignType: "guide"
        )
        await first.kill()

        // Corrupt the impression file; the app-event file must not notice.
        try Data("not a database, just garbage bytes".utf8).write(to: URL(fileURLWithPath: analyticsPath))
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: analyticsPath + suffix) }

        let second = try launch(sender)
        sender.online = true
        try await flushAll(second)

        #expect(sender.appEventNames == ["add_to_cart"])
        #expect(sender.eventNames.isEmpty)
        await second.kill()

        // And the other way: the impression survives losing the app-event file.
        let sender2 = PersistenceSender()
        let third = try launch(sender2)
        third.appEvents.track("add_to_cart")
        third.experience.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"), payload: testPayload("c1"),
            campaignId: "id", campaignType: "guide"
        )
        await third.kill()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: appEventsPath + suffix) }

        let fourth = try launch(sender2)
        sender2.online = true
        try await flushAll(fourth)

        #expect(sender2.appEventNames.isEmpty)
        #expect(sender2.eventNames == ["Digia Experience Viewed"])
        await fourth.kill()
    }

    // dmc-case: dmc.app_event.cap_survives_kill
    @Test("the 2,000-event cap holds across a kill, keeping the newest")
    func capSurvivesKill() async throws {
        defer { wipe() }
        let sender = PersistenceSender()
        let sink = ReasonSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        let first = try launch(sender)
        for i in 1...(appEventQueueMaxEvents + 1) { first.appEvents.track("e\(i)") }
        #expect(sink.reasons.contains("app_event_queue_full"))
        await first.kill()

        let second = try launch(sender)
        sender.online = true
        try await flushAll(second)

        let sent = sender.appEventNames
        #expect(sent.count == appEventQueueMaxEvents)
        #expect(sent.first == "e2")
        #expect(sent.last == "e\(appEventQueueMaxEvents + 1)")
        await second.kill()
    }
}
