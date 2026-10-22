import Foundation

/// Tracks how long each campaign instance was on screen.
///
/// `markViewed` stamps the moment a campaign becomes visible; `consumeDwellMs`
/// returns the elapsed time at dismissal and forgets the mark. Keyed by
/// `cepCampaignId`. Ported from Android `internal/event/DwellTracker.kt`.
@MainActor
final class DwellTracker {
    private final class DwellEntry {
        private var accumulatedMs: Int64
        private var lastResumedAtMs: Int64?

        init(accumulatedMs: Int64 = 0, lastResumedAtMs: Int64? = nil) {
            self.accumulatedMs = accumulatedMs
            self.lastResumedAtMs = lastResumedAtMs
        }

        var isRunning: Bool {
            lastResumedAtMs != nil
        }

        func resume(_ nowMs: Int64) {
            if lastResumedAtMs == nil {
                lastResumedAtMs = nowMs
            }
        }

        func pause(_ nowMs: Int64) {
            if let started = lastResumedAtMs {
                let delta = nowMs - started
                if delta > 0 { accumulatedMs += delta }
                lastResumedAtMs = nil
            }
        }

        func totalMs(_ nowMs: Int64) -> Int64 {
            let runningDelta = lastResumedAtMs.map { max(0, nowMs - $0) } ?? 0
            return accumulatedMs + runningDelta
        }
    }

    private let now: () -> Int64
    private var entries: [String: DwellEntry] = [:]
    private(set) var isPaused: Bool = false

    init(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
    }

    /// Records that `cepCampaignId` became visible now.
    func markViewed(_ cepCampaignId: String) {
        let entry = DwellEntry()
        if !isPaused {
            entry.resume(now())
        }
        entries[cepCampaignId] = entry
    }

    /// Pauses dwell timing for all active campaigns (e.g. app backgrounded).
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        let currentNow = now()
        for entry in entries.values {
            entry.pause(currentNow)
        }
    }

    /// Resumes dwell timing for all active campaigns (e.g. app foregrounded).
    func resume() {
        guard isPaused else { return }
        isPaused = false
        let currentNow = now()
        for entry in entries.values {
            entry.resume(currentNow)
        }
    }

    /// Returns ms since `markViewed` for `cepCampaignId` *without* forgetting the
    /// mark — for mid-life signals (e.g. a click while the campaign is still up).
    func elapsedMs(_ cepCampaignId: String) -> Int64? {
        guard let entry = entries[cepCampaignId] else { return nil }
        return entry.totalMs(now())
    }

    /// Returns ms elapsed since `markViewed` for `cepCampaignId` and forgets the
    /// mark, or nil if it was never marked (so callers omit the field).
    func consumeDwellMs(_ cepCampaignId: String) -> Int64? {
        guard let elapsed = elapsedMs(cepCampaignId) else { return nil }
        entries.removeValue(forKey: cepCampaignId)
        return elapsed
    }

    func clear() {
        entries.removeAll()
    }
}
