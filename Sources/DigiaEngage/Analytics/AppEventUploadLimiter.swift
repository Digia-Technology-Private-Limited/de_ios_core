import Foundation

/// Why one app event was not stored or uploaded.
enum AppEventDropReason: Equatable, Sendable {
    /// The bundle's upload switch is off.
    case disabled
    /// The event name is on the bundle's blocklist.
    case blocked
    /// The token bucket for the sustained rate is empty.
    case rate
}

/// The campaign bundle's app-event upload settings, which travel together.
struct AppEventUploadPolicy: Equatable, Sendable {
    /// Whether app events are stored and uploaded at all.
    var enabled = true
    /// The sustained upload rate per minute. 0 is unlimited.
    var ratePerMinute = 0
    /// The burst the token bucket starts with. 0 is one minute's worth.
    var burst = 0
    /// App-event names not to store or upload.
    var blockedNames: Set<String> = []

    /// Upload on, no rate limit, nothing blocked: what a bundle without the
    /// settings means.
    static let unlimited = AppEventUploadPolicy()
}

/// Bounds what the app-event queue stores and uploads, from the campaign
/// bundle's app-event settings.
///
/// A dropped event still reaches the signal bus, so campaigns can react to it;
/// only storing and uploading are skipped. The token bucket is per session and
/// in memory — the 2,000-event queue cap is the durable safety net.
///
/// This decides; ``AppEventsService`` reports the cause, and HealthSink keeps
/// the first per reason per session.
@MainActor
final class AppEventUploadLimiter {
    private let nowMs: () -> Int64
    private var policy = AppEventUploadPolicy.unlimited
    private var tokens = 0.0
    private var lastRefillMs: Int64 = 0

    init(nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.nowMs = nowMs
    }

    /// Applies the bundle's settings and refills the bucket.
    func applyPolicy(_ policy: AppEventUploadPolicy) {
        self.policy = policy
        tokens = Double(capacity)
        lastRefillMs = nowMs()
    }

    /// Allows one event named `eventName`, or says why it was dropped.
    func consume(_ eventName: String) -> AppEventDropReason? {
        if !policy.enabled { return .disabled }
        if policy.blockedNames.contains(eventName) { return .blocked }
        if ratePerMinute == 0 { return nil }

        refill()
        if tokens < 1 { return .rate }
        tokens -= 1
        return nil
    }

    private var ratePerMinute: Int { max(0, policy.ratePerMinute) }

    /// The bucket holds a full burst; with no burst named, one minute's worth.
    private var capacity: Int { policy.burst > 0 ? policy.burst : ratePerMinute }

    private func refill() {
        let now = nowMs()
        let elapsedMs = now - lastRefillMs
        if elapsedMs <= 0 { return }
        lastRefillMs = now
        tokens = min(Double(capacity), tokens + Double(elapsedMs) * Double(ratePerMinute) / 60_000)
    }
}
