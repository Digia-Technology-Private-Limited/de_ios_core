import Foundation

private let log = DigiaLogger("analytics")

/// How many app events the app-event queue keeps, oldest dropped first. The
/// safety net behind the bundle's upload limit.
let appEventQueueMaxEvents = 2000

/// Stores and uploads host-app events (`Digia.trackEvent`) through their own
/// queue, within the bundle's ``AppEventUploadPolicy``. The experience
/// ``AnalyticsService`` never sees them.
///
/// Batching, retry and lifecycle come from the ``AnalyticsService`` it wraps —
/// built on the app-event queue — so that logic lives in one place.
///
/// A drop emits one `sdk_health` row at the drop, and HealthSink keeps the first
/// per reason per session, so a flood is still one row per cause.
@MainActor
final class AppEventsService {
    private let service: AnalyticsService
    private let limiter: AppEventUploadLimiter

    init(_ service: AnalyticsService, limiter: AppEventUploadLimiter = AppEventUploadLimiter()) {
        self.service = service
        self.limiter = limiter
    }

    /// Applies the campaign bundle's app-event upload settings.
    func applyPolicy(_ policy: AppEventUploadPolicy) { limiter.applyPolicy(policy) }

    func flush() { service.flush() }

    func clear() { service.clear() }

    /// Test-only: the queued entries' payloads, oldest first.
    var queuedPayloads: [[String: Any]] { service.queue.peek(maxCount: Int.max).map(\.payload) }

    func track(_ eventName: String, properties: [String: Any] = [:]) {
        if let drop = limiter.consume(eventName) {
            reportDrop(drop)
            return
        }
        let evicted = service.trackAppEvent(eventName, properties: properties)
        if evicted > 0 {
            log.w(
                "App events evicted — the app-event queue reached its cap",
                stage: .session,
                reason: TimelineReason.appEventQueueFull
            )
        }
    }

    /// Upload-off is silent: it is configured behaviour, not a failure.
    private func reportDrop(_ reason: AppEventDropReason) {
        switch reason {
        case .disabled:
            return
        case .rate:
            log.d(
                "App event dropped by the bundle rate limit",
                stage: .session,
                reason: TimelineReason.appEventRateLimited
            )
        case .blocked:
            log.d(
                "App event dropped by the bundle name blocklist",
                stage: .session,
                reason: TimelineReason.appEventBlocked
            )
        }
    }
}
