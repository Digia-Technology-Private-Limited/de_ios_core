import Foundation

// Frequency capping for NUDGE and SURVEY campaigns, ported 1:1 from the Android
// SDK (`FrequencyEvaluator.kt` / `FrequencyManager.kt`) and the React Native
// evaluator (`frequencyEvaluator.ts`). The pure evaluator shares an identical
// golden matrix across all three platforms; `now` and `sessionId` are injected
// so the logic is fully deterministic and unit-testable.
//
// On RN-backed apps this caps nudge + survey only — guides are capped in JS and
// never reach native.

// MARK: - Types

struct FrequencyWindow: Equatable {
    let count: Int
    let window: String
}

struct FrequencyPolicy: Equatable {
    let maxTotal: Int?
    let maxPerWindow: FrequencyWindow?
    let stopOn: String?

    init(maxTotal: Int? = nil, maxPerWindow: FrequencyWindow? = nil, stopOn: String? = nil) {
        self.maxTotal = maxTotal
        self.maxPerWindow = maxPerWindow
        self.stopOn = stopOn
    }

    /// True when the policy carries at least one active constraint.
    var hasConstraint: Bool { maxTotal != nil || maxPerWindow != nil || stopOn != nil }

    /// Parses the opaque dashboard `frequency` object (camelCase keys). Returns
    /// `nil` for a missing object or one with no recognised constraint ("No cap"
    /// / inline). Legacy snake_case payloads carry no recognised keys → `nil`.
    static func fromJson(_ json: [String: Any]?) -> FrequencyPolicy? {
        guard let json else { return nil }
        let maxTotal = json.positiveInt("maxTotal")
        var window: FrequencyWindow?
        if let w = json.object("maxPerWindow") {
            let count = w.int("count", default: 0)
            let unit = w.nonBlankString("window")
            if count > 0, let unit { window = FrequencyWindow(count: count, window: unit) }
        }
        let stopOn = json.nonBlankString("stopOn")
        let policy = FrequencyPolicy(maxTotal: maxTotal, maxPerWindow: window, stopOn: stopOn)
        return policy.hasConstraint ? policy : nil
    }
}

/// Persisted per-campaign capping state. `total` (lifetime) and `windowCount`
/// (current window) are tracked independently so a per-window cap never
/// double-counts against `maxTotal`.
struct FrequencyState: Equatable {
    var total: Int = 0
    var windowCount: Int = 0
    var windowAnchorAt: Int64?
    var sessionId: String?
    var stoppedAt: Int64?
}

enum FrequencySkipReason { case maxTotal, window, stopped }

struct FrequencyEvalResult: Equatable {
    let allow: Bool
    let reason: FrequencySkipReason?

    init(_ allow: Bool, _ reason: FrequencySkipReason? = nil) {
        self.allow = allow
        self.reason = reason
    }
}

// MARK: - Pure evaluator

enum FrequencyEvaluator {

    private static let dayMs: Int64 = 86_400_000
    private static let windowMs: [String: Int64] = [
        "day": dayMs,
        "week": 7 * dayMs,
        "month": 30 * dayMs,
    ]

    /// Pure eligibility check. Blocks if ANY active constraint is exceeded:
    /// permanent stop, lifetime total, or the current window.
    static func evaluate(
        _ policy: FrequencyPolicy,
        _ state: FrequencyState?,
        _ now: Int64,
        _ sessionId: String?
    ) -> FrequencyEvalResult {
        guard let state else { return FrequencyEvalResult(true) }
        if state.stoppedAt != nil { return FrequencyEvalResult(false, .stopped) }
        if let maxTotal = policy.maxTotal, state.total >= maxTotal {
            return FrequencyEvalResult(false, .maxTotal)
        }
        if let w = policy.maxPerWindow {
            let effective = isWindowExpired(w, state, now, sessionId) ? 0 : state.windowCount
            if effective >= w.count { return FrequencyEvalResult(false, .window) }
        }
        return FrequencyEvalResult(true)
    }

    /// Record one show on "Digia Experience Viewed". Bumps the lifetime total and
    /// the window count, re-anchoring the window when it has rolled over.
    static func recordShow(
        _ policy: FrequencyPolicy,
        _ state: FrequencyState?,
        _ now: Int64,
        _ sessionId: String?
    ) -> FrequencyState {
        let prev = state ?? FrequencyState()
        let w = policy.maxPerWindow
        let fresh = w == nil || isWindowExpired(w!, prev, now, sessionId)
        let isTimeWindow = w != nil && w!.window != "session"
        let isSessionWindow = w != nil && w!.window == "session"
        var next = prev
        next.total = prev.total + 1
        next.windowCount = fresh ? 1 : prev.windowCount + 1
        if isTimeWindow { next.windowAnchorAt = fresh ? now : prev.windowAnchorAt }
        if isSessionWindow { next.sessionId = sessionId }
        return next
    }

    /// Permanently stop the campaign on "Digia Experience Completed" when the
    /// policy opted into stopOn. Idempotent: the first stop timestamp wins.
    static func recordStop(_ state: FrequencyState?, _ now: Int64) -> FrequencyState {
        var prev = state ?? FrequencyState()
        if prev.stoppedAt == nil { prev.stoppedAt = now }
        return prev
    }

    private static func isWindowExpired(
        _ w: FrequencyWindow,
        _ state: FrequencyState,
        _ now: Int64,
        _ sessionId: String?
    ) -> Bool {
        if w.window == "session" { return state.sessionId != sessionId }
        guard let ms = windowMs[w.window] else { return true }
        guard let anchor = state.windowAnchorAt else { return true }
        return now - anchor >= ms
    }
}

// MARK: - Persistent manager

/// Stateful façade over the pure evaluator. Persists per-campaign state in
/// `UserDefaults` (JSON string keyed `"freq:<campaignKey>"`) and resolves the
/// current sessionId + clock through injected closures, matching Android's
/// `FrequencyManager`.
final class FrequencyManager {
    static let keyPrefix = "freq:"
    static let stopOnExperienceCompleted = "experienceCompleted"

    private let defaults: UserDefaults
    private let sessionIdProvider: () -> String?
    private let clock: () -> Int64

    init(
        defaults: UserDefaults = .standard,
        sessionIdProvider: @escaping () -> String?,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.defaults = defaults
        self.sessionIdProvider = sessionIdProvider
        self.clock = clock
    }

    /// Eligibility gate. A `nil`/empty policy is always allowed (never capped).
    func isAllowed(campaignKey: String, policy: FrequencyPolicy?) -> Bool {
        blockReason(campaignKey: campaignKey, policy: policy) == nil
    }

    /// The reason this campaign would be capped right now, or `nil` when it is
    /// allowed (or carries no constraint). Drives the gate via `isAllowed` and lets
    /// the route emit a verbose "why it was dropped" log without re-deriving it.
    func blockReason(campaignKey: String, policy: FrequencyPolicy?) -> FrequencySkipReason? {
        guard let policy, policy.hasConstraint else { return nil }
        return FrequencyEvaluator.evaluate(policy, load(campaignKey), clock(), sessionIdProvider()).reason
    }

    /// Bump on "Digia Experience Viewed". No-op for an uncapped policy.
    func recordShow(_ campaignKey: String, _ policy: FrequencyPolicy?) {
        guard let policy, policy.hasConstraint else { return }
        let next = FrequencyEvaluator.recordShow(policy, load(campaignKey), clock(), sessionIdProvider())
        save(campaignKey, next)
    }

    /// Permanent stop on "Digia Experience Completed" — only when the policy set
    /// `stopOn: experienceCompleted`. Idempotent.
    func recordCompleted(_ campaignKey: String, _ policy: FrequencyPolicy?) {
        guard policy?.stopOn == Self.stopOnExperienceCompleted else { return }
        let prev = load(campaignKey)
        if prev?.stoppedAt != nil { return }
        save(campaignKey, FrequencyEvaluator.recordStop(prev, clock()))
    }

    // ── Persistence ───────────────────────────────────────────────────────────

    private func keyFor(_ campaignKey: String) -> String { "\(Self.keyPrefix)\(campaignKey)" }

    private func load(_ campaignKey: String) -> FrequencyState? {
        guard let raw = defaults.string(forKey: keyFor(campaignKey)),
              let data = raw.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return FrequencyState(
            total: o.int("total", default: 0),
            windowCount: o.int("windowCount", default: 0),
            windowAnchorAt: o["windowAnchorAt"] != nil ? o.long("windowAnchorAt", default: 0) : nil,
            sessionId: o.nonBlankString("sessionId"),
            stoppedAt: o["stoppedAt"] != nil ? o.long("stoppedAt", default: 0) : nil
        )
    }

    private func save(_ campaignKey: String, _ state: FrequencyState) {
        var o: [String: Any] = ["total": state.total, "windowCount": state.windowCount]
        if let anchor = state.windowAnchorAt { o["windowAnchorAt"] = anchor }
        if let sessionId = state.sessionId { o["sessionId"] = sessionId }
        if let stoppedAt = state.stoppedAt { o["stoppedAt"] = stoppedAt }
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: keyFor(campaignKey))
    }
}
