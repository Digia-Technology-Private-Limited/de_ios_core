import Foundation
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger("analytics")

// MARK: - AnalyticsService

@MainActor
final class AnalyticsService {
    private let config: AnalyticsConfig
    /// [AnalyticsConfig.maxBatchSize] clamped to 1...``AnalyticsConfig/maxBatchSizeLimit``.
    private let maxBatchSize: Int
    var isEnabled: Bool { config.enabled }
    let identityManager: IdentityManager
    let sessionManager: SessionManager
    let queue: any AnalyticsQueueProtocol
    private let staticContext: [String: Any]
    private let networkClient: any NetworkClient

    private var isCleared = false
    private var flushTimer: Timer?
    /// Non-nil for the whole lifetime of a scheduled backoff wait (including
    /// while the resulting `dispatchPending()` call is actually running) — so
    /// `enqueue` can tell "a retry will happen" and defer to it instead of
    /// jumping ahead with an early flush.
    private var retryTask: Task<Void, Never>?
    /// True when `retryTask` retries a send that never reached the server.
    private var retryIsForTransport = false
    /// Sends in a row that got no HTTP response (no network, DNS, timeout).
    /// Sets the backoff for those retries only: they never count toward an
    /// event's attempts.
    private var transportFailures = 0
    private let networkMonitor: any NetworkMonitor
    /// Keeps the app running long enough to finish the send started on
    /// entering the background.
    private let backgroundTime: BackgroundTimeProvider
    private var isDispatching = false
    /// Attempt number of the most recently scheduled retry, reset to 0 on
    /// success. Diagnostic mirror only — the real retry-cap enforcement reads
    /// the persisted per-event counter in `AnalyticsQueue`, not this value, so
    /// it survives app restarts correctly.
    private(set) var retryAttempt = 0
    private var backgroundObserver: NSObjectProtocol?

    /// Override retry delays (ms) for testing. Index is attempt-1.
    var retryScheduleMs: [Int]?

    /// A send the server answered with 4xx/5xx is retried up to this many
    /// times. A send that got no response at all (no connectivity, timeout,
    /// DNS failure) is never counted — see `handleTransportFailure`. An event
    /// the server explicitly rejected (named in a 200/207 response's error
    /// list) is dropped immediately instead — that's not an API-call failure.
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
        identityManager: IdentityManager,
        sessionManager: SessionManager,
        queue: any AnalyticsQueueProtocol,
        staticContext: [String: Any],
        networkClient: any NetworkClient,
        networkMonitor: any NetworkMonitor = AlwaysOnlineNetworkMonitor(),
        backgroundTime: BackgroundTimeProvider = UIKitBackgroundTime()
    ) {
        self.config = config
        self.networkMonitor = networkMonitor
        self.backgroundTime = backgroundTime
        self.maxBatchSize = Self.boundedBatchSize(config.maxBatchSize)
        self.identityManager = identityManager
        self.sessionManager = sessionManager
        self.queue = queue
        self.staticContext = staticContext
        self.networkClient = networkClient

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelTimer()
                await withBackgroundTime(self.backgroundTime, name: "DigiaEngage analytics flush") {
                    await self.dispatchPending()
                }
            }
        }

        networkMonitor.start { [weak self] online in
            Task { @MainActor [weak self] in await self?.networkChanged(online: online) }
        }

        // Events left by an earlier process: the stored count is known only
        // once the queue has opened its database, off the main actor.
        Task { @MainActor [weak self] in
            guard let self, await self.queue.count() > 0, !self.isCleared else { return }
            self.scheduleTimer()
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
        impressionId: String? = nil
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
            impressionId: impressionId,
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

    func flush() {
        cancelTimer()
        Task { await dispatchPending() }
    }

    /// Cancels timers and removes lifecycle observers. Call before releasing the service.
    func clear() {
        isCleared = true
        networkMonitor.stop()
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

    private var jsonHeaders: [String: String] {
        ["Content-Type": "application/json"]
    }

    // MARK: - Private

    private func enqueue(
        eventName: String,
        campaignId: String?,
        campaignKey: String?,
        campaignType: String?,
        impressionId: String? = nil,
        properties: [String: Any] = [:]
    ) {
        let eventId = UUID().uuidString
        sessionManager.touch()

        let copiedStatic = Self.deepCopyMap(staticContext)
        let copiedProperties = Self.deepCopyMap(properties)
        var mergedProperties = copiedStatic
        for (k, v) in copiedProperties { mergedProperties[k] = v }

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
        if let impressionId { payloadMap["impression_id"] = impressionId }
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

    /// Offline: nothing is sent and nothing is scheduled — the network's
    /// return sends. Online: sends at once, unless a retry for a server
    /// failure is pending, whose backoff a network change must not cut short.
    private func networkChanged(online: Bool) async {
        guard !isCleared else { return }
        guard online else {
            log.d("Offline — sending paused until the network returns")
            return
        }
        transportFailures = 0
        guard queue.size > 0, retryTask == nil || retryIsForTransport else { return }
        log.d("Network available — sending queued events")
        retryTask?.cancel()
        retryTask = nil
        cancelTimer()
        await dispatchPending()
    }

    private func dispatchPending() async {
        guard !isCleared else { return }
        guard !isDispatching else {
            log.d("Dispatch skipped — already dispatching")
            return
        }
        guard networkMonitor.isOnline else {
            log.d("Dispatch deferred — offline; the network's return will send")
            return
        }
        cancelTimer()
        isDispatching = true
        defer {
            isDispatching = false
            // Events can be left behind two ways: a batch capped at maxBatchSize, and an event
            // captured while this dispatch was in flight (its own dispatch was skipped as "already
            // dispatching", and scheduleTimer is a no-op while dispatching). Neither has a timer, so
            // arm one here at the configured interval, unless a retry is already pending and will
            // pick them up.
            if queue.size > 0 && retryTask == nil && flushTimer == nil && networkMonitor.isOnline {
                scheduleTimer()
            }
        }

        let batch = await queue.peek(maxCount: maxBatchSize)
        guard !batch.isEmpty else {
            log.d("Dispatch skipped — the queue is empty")
            retryAttempt = 0
            return
        }

        log.d("Batch posting (count=\(batch.count), endpoint=\(DigiaEndpoints.track))")

        do {
            // Built off the main actor. Every stored payload was validated as
            // JSON when it was queued.
            let body = try await Task.detached(priority: .utility) {
                try JSONSerialization.data(withJSONObject: ["events": batch.map { $0.payload }])
            }.value
            guard let url = URL(string: DigiaEndpoints.track) else { return }
            let request = NetworkRequest(url: url, method: .post, headers: jsonHeaders, body: body)
            let response: NetworkResponse
            do {
                response = try await networkClient.execute(request: request)
            } catch {
                // No HTTP response: the request never reached the server.
                handleTransportFailure(cause: error.localizedDescription)
                return
            }
            transportFailures = 0
            let statusCode = response.statusCode
            log.d("Batch posted (status=\(statusCode))")

            switch statusCode {
            case 200, 207:
                // Any per-event rejections named in the response body were never
                // retried in the first place — see `logRejected`/response parsing;
                // the whole batch (accepted + rejected) is simply removed here.
                logRejected(response.body)
                retryAttempt = 0
                await queue.remove(eventIds: batch.map { $0.eventId })
                log.d("Batch accepted (count=\(batch.count), queueSize=\(queue.size))")
            default:
                // The server answered and refused: 4xx or 5xx, retried
                // uniformly, capped.
                await handleFailure(batch: batch, statusLabel: "HTTP \(statusCode)")
            }
        } catch {
            // Not a network failure (e.g. the body could not be built): counted,
            // so a batch that can never be sent is eventually dropped.
            log.d("Batch post failed (cause=\(error.localizedDescription))")
            await handleFailure(batch: batch, statusLabel: "exception: \(error.localizedDescription)")
        }
    }

    /// The send got no HTTP response: no network, DNS failure, timeout. The
    /// events stay and their attempts are not counted — losing the network is
    /// not the events' fault. Offline, nothing is scheduled: the network's
    /// return sends. Online (a captive portal, an unreachable host), retried
    /// on the same capped backoff, indefinitely.
    /// Logs each event the server named as rejected in a 200/207 body. They are
    /// removed with the rest of the batch: sending them again would be rejected
    /// again. An empty or unreadable body names none.
    private func logRejected(_ body: Data?) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let errors = json["errors"] as? [Any]
        else { return }
        for case let error as [String: Any] in errors {
            let eventId = error["event_id"] as? String ?? ""
            let reason = error["reason"] as? String ?? ""
            log.e("Event rejected (eventId=\(eventId), reason=\(reason))")
        }
    }

    private func handleTransportFailure(cause: String) {
        transportFailures += 1
        guard networkMonitor.isOnline else {
            log.d("Batch not sent — offline; waiting for the network (cause=\(cause))")
            return
        }
        log.d("Batch not sent — no response; retry #\(transportFailures) scheduled, attempts not counted (cause=\(cause))")
        scheduleRetry(attempt: transportFailures, forTransport: true)
    }

    /// Increments the attempt counter for the failed batch, drops whichever
    /// events have now exhausted the retry cap, and schedules a backoff retry
    /// for the rest (if any remain).
    private func handleFailure(batch: [QueueEntry], statusLabel: String) async {
        let updated = await queue.incrementAttempt(eventIds: batch.map { $0.eventId })

        let toDrop = updated.filter { $0.attempts >= Self.maxAttempts }
        let toRetry = updated.filter { $0.attempts < Self.maxAttempts }

        if !toDrop.isEmpty {
            await queue.remove(eventIds: toDrop.map { $0.eventId })
            log.e(
                "Batch post failed — dropped \(toDrop.count) event(s) after exhausting "
                    + "\(Self.maxAttempts) attempts (cause=\(statusLabel))"
            )
        }

        guard !toRetry.isEmpty else {
            retryAttempt = 0
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
        guard flushTimer == nil, !isDispatching, networkMonitor.isOnline else { return }
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

    private func scheduleRetry(attempt: Int, forTransport: Bool = false) {
        retryTask?.cancel()
        retryIsForTransport = forTransport
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
        // Clamped: transport retries are uncapped in number, so `attempt` can
        // grow past 10, and an unclamped shift would overflow.
        let exponent = min(max(attempt - 1, 0), 20)
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

    /// Below 1 nothing would ever be sent; above the limit each dispatch
    /// stalls the main actor encoding and decoding one large batch.
    static func boundedBatchSize(_ configured: Int) -> Int {
        let bounded = min(max(configured, 1), AnalyticsConfig.maxBatchSizeLimit)
        if bounded != configured {
            log.w("maxBatchSize \(configured) is outside 1...\(AnalyticsConfig.maxBatchSizeLimit) — using \(bounded)")
        }
        return bounded
    }

    static func deepClone(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return deepCopyMap(dict)
        } else if let arr = value as? [Any] {
            return arr.map { deepClone($0) }
        } else if let set = value as? Set<AnyHashable> {
            return Set(set.map { deepClone($0) as! AnyHashable })
        }
        return value
    }

    static func deepCopyMap(_ source: [String: Any]) -> [String: Any] {
        var copy = [String: Any]()
        for (k, v) in source {
            copy[k] = deepClone(v)
        }
        return copy
    }
}
