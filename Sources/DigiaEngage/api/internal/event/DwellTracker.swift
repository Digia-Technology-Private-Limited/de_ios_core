import Foundation

/// Tracks how long each campaign instance was on screen.
///
/// `markViewed` stamps the moment a campaign becomes visible; `consumeDwellMs`
/// returns the elapsed time at dismissal and forgets the mark. Keyed by
/// `cepCampaignId`. Ported from Android `internal/event/DwellTracker.kt`.
@MainActor
final class DwellTracker {
    private let now: () -> Int64
    private var viewedAtMs: [String: Int64] = [:]

    init(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
    }

    /// Records that `cepCampaignId` became visible now.
    func markViewed(_ cepCampaignId: String) {
        viewedAtMs[cepCampaignId] = now()
    }

    /// Returns ms since `markViewed` for `cepCampaignId` *without* forgetting the
    /// mark — for mid-life signals (e.g. a click while the campaign is still up).
    func elapsedMs(_ cepCampaignId: String) -> Int64? {
        viewedAtMs[cepCampaignId].map { now() - $0 }
    }

    /// Returns ms elapsed since `markViewed` for `cepCampaignId` and forgets the
    /// mark, or nil if it was never marked (so callers omit the field).
    func consumeDwellMs(_ cepCampaignId: String) -> Int64? {
        guard let viewedAt = viewedAtMs.removeValue(forKey: cepCampaignId) else { return nil }
        return now() - viewedAt
    }

    func clear() {
        viewedAtMs.removeAll()
    }
}
