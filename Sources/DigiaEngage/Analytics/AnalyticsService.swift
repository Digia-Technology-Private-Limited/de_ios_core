import Foundation
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger("analytics")

// MARK: - AnalyticsService

@MainActor
final class AnalyticsService {
    private let config: AnalyticsConfig
    private let apiKey: String
    let identityManager: IdentityManager
    let sessionManager: SessionManager
    let queue: AnalyticsQueue
    private let staticContext: [String: Any]
    private let networkClient: any NetworkClient
    private let requestHeaders: [String: String]

    private var isCleared = false
    private var flushTimer: Timer?
    /// Non-nil for the whole lifetime of a scheduled backoff wait (including
    /// while the resulting `dispatchPending()` call is actually running) — so
    /// `enqueue` can tell "a retry will happen" and defer to it instead of
    /// jumping ahead with an early flush.
    private var retryTask: Task<Void, Never>?
    private var isDispatching = false
    /// Attempt number of the most recently scheduled retry, reset to 0 on
    /// success. Diagnostic mirror only — the real retry-cap enforcement reads
    /// the persisted per-event counter in `AnalyticsQueue`, not this value, so
    /// it survives app restarts correctly.
    private(set) var retryAttempt = 0
    private var backgroundObserver: NSObjectProtocol?

    /// Override retry delays (ms) for testing. Index is attempt-1.
    var retryScheduleMs: [Int]?

    /// Any failed API call (4xx, 5xx, or a thrown error — no connectivity,
    /// timeout, DNS failure) is retried up to this many times. An event the
    /// server explicitly rejected (named in a 200/207 response's error list)
    /// is dropped immediately instead — that's not an API-call failure.
    private static let maxAttempts = 10
    /// 10 attempts at a low, fixed cap would mostly sit at the floor after a
    /// few seconds, which isn't a meaningful amount of patience for a real
    /// connectivity gap (e.g. a subway commute) — so the ceiling is high.
    private static let backoffCeilingMs = 120_000
    /// ± this fraction of jitter applied to every backoff delay, so many
    /// clients recovering from the same outage don't retry in lockstep.
    private static let jitterFraction = 0.2

    init(
        config: AnalyticsConfig,
        apiKey: String,
        identityManager: IdentityManager,
        sessionManager: SessionManager,
        queue: AnalyticsQueue,
        staticContext: [String: Any],
        networkClient: any NetworkClient = URLSessionNetworkClient(),
        requestHeaders: [String: String] = [:]
    ) {
        self.config = config
        self.apiKey = apiKey
        self.identityManager = identityManager
        self.sessionManager = sessionManager
        self.queue = queue
        self.staticContext = staticContext
        self.networkClient = networkClient
        self.requestHeaders = requestHeaders

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelTimer()
                await self.dispatchPending()
            }
        }

        if queue.size > 0 {
            scheduleTimer()
        }
    }

    // MARK: - Public

    /// Records a rich, campaign-grouped ``EngageAnalyticsEvent``. The event's
    /// `properties` are nested under `properties` on the wire payload. Campaign
    /// id/type are resolved by the caller (``DigiaAnalyticsSink``) from the
    /// campaign store.
    func capture(
        _ event: EngageAnalyticsEvent,
        payload: CEPTriggerPayload,
        campaignId: String?,
        campaignType: String?,
        presentationId: String? = nil
    ) {
        guard config.enabled else {
            log.d("Event dropped — analytics disabled (event=\(event.eventName))")
            return
        }
        log.d(
            "Event captured: \"\(event.eventName)\" (cepCampaignId=\(campaignId ?? "nil"))",
            campaign: payload.campaignKey
        )

        enqueue(
            eventName: event.eventName,
            campaignId: campaignId,
            campaignKey: payload.campaignKey,
            campaignType: campaignType,
            presentationId: presentationId,
            properties: event.properties
        )
    }

    /// Captures one SDK health event for Digia's own fleet diagnostics.
    ///
    /// An ordinary first-party event — same envelope, same queue, same
    /// batching, retry and identity — distinguished only by its event name.
    /// That is the whole point: transport code is exactly the code the SDK's
    /// release chain says not to ship twice.
    ///
    /// Narrow on purpose. A general-public `enqueue` would put event naming
    /// back at the call sites, which is the drift `HealthSink`'s central
    /// allowlist exists to prevent; this is the one door, and `HealthSink` is
    /// the one caller. Its properties are already projected to an explicit,
    /// symbol-only field list — nothing here re-reads a record.
    func captureHealth(
        campaignKey: String?,
        reason: String,
        stage: String?,
        detail: [String: String]?,
        buildMode: String
    ) {
        guard config.enabled else { return }
        var properties: [String: Any] = ["reason": reason, "build_mode": buildMode]
        if let stage { properties["stage"] = stage }
        if let detail, !detail.isEmpty { properties["detail"] = detail }
        enqueue(
            eventName: HealthSink.eventName,
            campaignId: nil,
            campaignKey: campaignKey,
            campaignType: nil,
            properties: properties
        )
    }

    func setUserId(_ userId: String) {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard identityManager.userId != trimmed else { return }
        identityManager.setUserId(trimmed)
        sessionManager.reset()
    }

    func clearUserId() {
        guard identityManager.userId != nil else { return }
        identityManager.clearUserId()
        sessionManager.reset()
    }

    var userId: String? { identityManager.userId }

    func flush() {
        cancelTimer()
        Task { await dispatchPending() }
    }

    /// Cancels timers and removes lifecycle observers. Call before releasing the service.
    func clear() {
        isCleared = true
        retryTask?.cancel()
        retryTask = nil
        cancelTimer()
        if let obs = backgroundObserver { NotificationCenter.default.removeObserver(obs) }
        backgroundObserver = nil
        isDispatching = false
        retryAttempt = 0
    }

    /// Cancels in-flight state without clearing the queue. Mirrors Android's resetForTest().
    func resetForTest() {
        cancelTimer()
        isDispatching = false
        retryAttempt = 0
    }

    // MARK: - Factory

    @MainActor
    static func create(
        config: DigiaConfig,
        requestHeaders: [String: String],
        storage: LocalStorage = UserDefaultsLocalStorage(),
        identityManager: IdentityManager? = nil,
        sessionManager: SessionManager? = nil,
        networkClient: (any NetworkClient)? = nil
    ) -> AnalyticsService? {
        let ac = config.analyticsConfig
        guard ac.enabled else {
            log.i("Analytics disabled in DigiaConfig — no events will be captured")
            return nil
        }
        log.d(
            "Analytics enabled (batchSize=\(ac.flushBatchSize), interval=\(ac.flushIntervalMs)ms)"
        )
        let resolvedIdentityManager = identityManager ?? IdentityManager(storage: storage.scoped("identity"))
        let resolvedSessionManager = sessionManager ?? SessionManager(
            storage: storage,
            timeoutMs: Int64(ac.sessionTimeoutMs)
        )
        return AnalyticsService(
            config: ac,
            apiKey: config.apiKey,
            identityManager: resolvedIdentityManager,
            sessionManager: resolvedSessionManager,
            queue: AnalyticsQueue(storage: storage.scoped("analytics")),
            staticContext: buildStaticContext(
                wrapperBinding: config.wrapperBinding,
                wrapperVersion: config.wrapperVersion
            ),
            networkClient: networkClient ?? URLSessionNetworkClient(),
            requestHeaders: requestHeaders
        )
    }

    private var jsonHeaders: [String: String] {
        requestHeaders.merging([
            "Content-Type": "application/json",
            "X-Digia-Project-Id": apiKey,
            "X-Digia-Device-Id": identityManager.deviceId,
        ]) { _, value in value }
    }

    // MARK: - Private

    private func enqueue(
        eventName: String,
        campaignId: String?,
        campaignKey: String?,
        campaignType: String?,
        presentationId: String? = nil,
        properties: [String: Any] = [:]
    ) {
        let eventId = UUID().uuidString
        sessionManager.touch()

        var mergedProperties = staticContext
        for (k, v) in properties { mergedProperties[k] = v }

        var payloadMap: [String: Any] = [
            "event_id": eventId,
            "event_name": eventName,
            "occurred_at": isoNow(),
            "anonymous_id": identityManager.deviceId,
            "session_id": sessionManager.sessionId,
        ]
        if let id = campaignId { payloadMap["campaign_id"] = id }
        if let key = campaignKey { payloadMap["campaign_key"] = key }
        if let type = campaignType { payloadMap["campaign_type"] = type }
        // The key that groups every event from one showing. `campaign_key`
        // cannot do that job: the same campaign can be delivered many times in
        // a session. Absent, not null, when there is none — a live test, or a
        // surface outliving its presentation.
        if let presentationId { payloadMap["presentation_id"] = presentationId }
        if let uid = identityManager.userId { payloadMap["user_id"] = uid }
        if let elementId = properties["element_id"] as? String {
            payloadMap["element_id"] = elementId
        }

        payloadMap["properties"] = mergedProperties

        queue.append(
            QueueEntry(
                eventId: eventId, payload: payloadMap, createdAt: Date().timeIntervalSince1970,
                attempts: 0),
            maxEvents: config.queueMaxEvents
        )
        log.d(
            "Event enqueued (event='\(eventName)', eventId=\(eventId), queueSize=\(queue.size), flushBatchSize=\(config.flushBatchSize))"
        )

        guard retryTask == nil else {
            // A backoff-scheduled retry is already pending — it will pick up
            // this event (and everything else queued) when it fires. Don't
            // jump the queue and flush early just because new events pushed
            // us past the threshold.
            log.d("Dispatch deferred — a retry is already scheduled")
            return
        }

        if queue.size >= config.flushBatchSize {
            log.d("Batch threshold reached — dispatching immediately")
            cancelTimer()
            Task { await dispatchPending() }
        } else {
            log.d("Flush timer scheduled (interval=\(config.flushIntervalMs)ms)")
            scheduleTimer()
        }
    }

    private func dispatchPending() async {
        guard !isCleared else { return }
        guard !isDispatching else {
            log.d("Dispatch skipped — already dispatching")
            return
        }
        cancelTimer()
        isDispatching = true
        defer { isDispatching = false }

        let batch = queue.peek(maxCount: config.maxBatchSize)
        guard !batch.isEmpty else {
            log.d("Dispatch skipped — the queue is empty")
            retryAttempt = 0
            return
        }

        log.d("Batch posting (count=\(batch.count), endpoint=\(DigiaEndpoints.track))")

        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "events": batch.map { $0.payload }
            ])
            guard let url = URL(string: DigiaEndpoints.track) else { return }
            let request = NetworkRequest(url: url, method: .post, headers: jsonHeaders, body: body)
            let response = try await networkClient.execute(request: request)
            let statusCode = response.statusCode
            log.d("Batch posted (status=\(statusCode))")

            switch statusCode {
            case 200, 207:
                // Any per-event rejections named in the response body were never
                // retried in the first place — see `logRejected`/response parsing;
                // the whole batch (accepted + rejected) is simply removed here.
                queue.remove(eventIds: batch.map { $0.eventId })
                retryAttempt = 0
                log.d("Batch accepted (count=\(batch.count), queueSize=\(queue.size))")
                if queue.size > 0 { scheduleTimer(minDelayMs: 15_000) }
            default:
                // Any other outcome is just "the API call failed" — 4xx, 5xx, or
                // no real status at all — retried uniformly, capped.
                handleFailure(batch: batch, statusLabel: "HTTP \(statusCode)")
            }
        } catch {
            // Verbose only — a single thrown exception is just one attempt in a
            // retry sequence, not yet a final outcome. Only the eventual drop
            // (after exhausting the cap) is warning-level.
            log.d("Batch post failed (cause=\(error.localizedDescription))")
            handleFailure(batch: batch, statusLabel: "exception: \(error.localizedDescription)")
        }
    }

    /// Increments the attempt counter for the failed batch, drops whichever
    /// events have now exhausted the retry cap, and schedules a backoff retry
    /// for the rest (if any remain).
    private func handleFailure(batch: [QueueEntry], statusLabel: String) {
        let updated = queue.incrementAttempt(eventIds: batch.map { $0.eventId })

        let toDrop = updated.filter { $0.attempts >= Self.maxAttempts }
        let toRetry = updated.filter { $0.attempts < Self.maxAttempts }

        if !toDrop.isEmpty {
            queue.remove(eventIds: toDrop.map { $0.eventId })
            log.e(
                "Batch post failed — dropped \(toDrop.count) event(s) after exhausting "
                    + "\(Self.maxAttempts) attempts (cause=\(statusLabel))"
            )
        }

        guard !toRetry.isEmpty else {
            retryAttempt = 0
            if queue.size > 0 { scheduleTimer(minDelayMs: 15_000) }
            return
        }

        let attempt = toRetry.map { $0.attempts }.max() ?? 1
        // Verbose only — an in-progress retry isn't yet a problem; only the
        // eventual drop above (cap exhausted) is warning-level.
        log.d(
            "Batch post failed — retry #\(attempt) scheduled for \(toRetry.count) event(s) "
                + "(cause=\(statusLabel))"
        )
        scheduleRetry(attempt: attempt)
    }

    private func scheduleTimer(minDelayMs: Int = 0) {
        guard flushTimer == nil, !isDispatching else { return }
        let delayMs = max(config.flushIntervalMs, minDelayMs)
        flushTimer = Timer.scheduledTimer(
            withTimeInterval: Double(delayMs) / 1_000,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flushTimer = nil
                await self.dispatchPending()
            }
        }
    }

    private func cancelTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    private func scheduleRetry(attempt: Int) {
        retryAttempt = attempt
        let delayMs = retryDelayMs(attempt)
        let delayNs = UInt64(delayMs) * 1_000_000
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled, let self, !self.isCleared else { return }
            self.retryTask = nil
            await self.dispatchPending()
        }
    }

    private func retryDelayMs(_ attempt: Int) -> Int {
        // The test override is meant to give exact, deterministic timing, so it
        // deliberately bypasses jitter.
        if let schedule = retryScheduleMs {
            let idx = max(0, min(attempt - 1, schedule.count - 1))
            return schedule[idx]
        }
        // Exponential backoff, capped. The cap (10) keeps `attempt` small enough
        // that `1 << (attempt - 1)` can't overflow Int.
        let exponent = max(attempt - 1, 0)
        let base = min(1_000 * (1 << exponent), Self.backoffCeilingMs)
        return applyJitter(base)
    }

    /// Randomizes `delayMs` by ± `jitterFraction` so many clients recovering
    /// from the same outage don't all retry at the exact same instant.
    private func applyJitter(_ delayMs: Int) -> Int {
        let range = Double(delayMs) * Self.jitterFraction
        let jitter = Double.random(in: -range...range)
        return max(0, Int(Double(delayMs) + jitter))
    }

    private func isoNow() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }

    static func buildStaticContext(
        wrapperBinding: String?,
        wrapperVersion: String?
    ) -> [String: Any] {
        let platform = "ios"
        let binding = wrapperBinding ?? "native"
        var ctx: [String: Any] = [
            "sdk_version": buildSdkVersion(
                binding: binding,
                platform: platform,
                wrapperVersion: wrapperVersion,
                core: DigiaSdkVersion.value
            ),
            "sdk_platform": binding == "native" ? platform : binding,
            "device_platform": platform,
            "device_make": "Apple",
            "app_locale": Locale.current.identifier,
        ]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        ctx["os_version"] = "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            ctx["app_version"] = version
        }
        var sysInfo = utsname()
        uname(&sysInfo)
        let machine = withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        if !machine.isEmpty { ctx["device_model"] = machine }
        return ctx
    }

}
