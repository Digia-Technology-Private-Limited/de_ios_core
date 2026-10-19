import Darwin
import Foundation

/// Milliseconds that keep counting while the phone sleeps: Darwin's
/// `CLOCK_MONOTONIC` continues to increment while the system is asleep, unlike
/// `CLOCK_MONOTONIC_RAW`, and is unaffected by wall-clock changes.
enum MonotonicClock {
    static func nowMs() -> Int {
        Int(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
    }
}

/// Why a pending wait ended without its campaign being shown.
enum WaitCancelCause: String {
    case event
    case screenViewed = "screen_viewed"
    case screenLeft = "screen_left"
    case sessionEnded = "session_ended"

    var wire: String { rawValue }
}

/// One campaign that a trigger matched and that now waits for its delay.
struct PendingWait {
    let campaignKey: String
    let priority: Double
    let wait: RuleWait
    /// The signal that started the wait. Its properties are evaluated again
    /// when the wait ends.
    let trigger: RuleSignal
    /// The screen when the wait started, for `screen_left` without names.
    /// Empty when no screen was set.
    let screen: String
    let endsAtMs: Int
}

/// The running `delay` waits, at most one per campaign; waits of different
/// campaigns run in parallel. In memory only: a process end drops them.
///
/// Each wait stores its end on `nowMs`, a clock that keeps counting in the
/// background. Timers run only in the foreground; ``resume()`` fires every wait
/// that ended meanwhile.
@MainActor
final class Waits {
    /// The waits that ended at the same moment, highest priority first.
    var onElapsed: ([PendingWait]) -> Void
    private let nowMs: () -> Int
    private var pending: [String: PendingWait] = [:]
    private var timer: Timer?
    private var foreground = true

    init(onElapsed: @escaping ([PendingWait]) -> Void, nowMs: @escaping () -> Int) {
        self.onElapsed = onElapsed
        self.nowMs = nowMs
    }

    func isWaiting(_ campaignKey: String) -> Bool {
        pending[campaignKey] != nil
    }

    /// Starts the waits that `trigger` matched, each `elapsedMs` into its
    /// delay. A campaign that already waits keeps its first timer. Waits that
    /// have already ended compete together, highest priority first.
    func start(
        _ waits: [(campaignKey: String, priority: Double, wait: RuleWait)],
        trigger: RuleSignal,
        screen: String,
        elapsedMs: Int = 0
    ) {
        for entry in waits where !isWaiting(entry.campaignKey) {
            pending[entry.campaignKey] = PendingWait(
                campaignKey: entry.campaignKey,
                priority: entry.priority,
                wait: entry.wait,
                trigger: trigger,
                screen: screen,
                endsAtMs: nowMs() + entry.wait.ms - elapsedMs
            )
        }
        schedule()
    }

    /// Ends every wait that `signal` cancels, each with its cause.
    func cancelMatching(_ signal: RuleSignal) -> [(PendingWait, WaitCancelCause)] {
        var cancelled: [(PendingWait, WaitCancelCause)] = []
        for wait in pending.values {
            for cancel in wait.wait.cancels {
                if let cause = Self.cause(cancel, signal: signal, waitScreen: wait.screen) {
                    cancelled.append((wait, cause))
                    break
                }
            }
        }
        guard !cancelled.isEmpty else { return cancelled }
        for (wait, _) in cancelled {
            pending.removeValue(forKey: wait.campaignKey)
        }
        schedule()
        return cancelled
    }

    /// Ends every wait, as on a session end.
    func cancelAll() -> [PendingWait] {
        let all = Array(pending.values)
        pending.removeAll()
        schedule()
        return all
    }

    func pause() {
        foreground = false
        schedule()
    }

    func resume() {
        foreground = true
        schedule()
    }

    /// Fires the waits that have ended, then sets one timer for the next end.
    /// Internal so a test can run the clock forward without a real timer.
    func schedule() {
        timer?.invalidate()
        timer = nil
        guard foreground, !pending.isEmpty else { return }
        let now = nowMs()
        var due = pending.values.filter { $0.endsAtMs <= now }
        due.sort {
            compareByPriority(
                $0.priority, $0.campaignKey, $1.priority, $1.campaignKey) < 0
        }
        for wait in due {
            pending.removeValue(forKey: wait.campaignKey)
        }
        if let next = pending.values.map(\.endsAtMs).min() {
            let interval = max(0, next - now)
            timer = Timer.scheduledTimer(withTimeInterval: Double(interval) / 1_000, repeats: false) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.schedule() }
            }
        }
        if !due.isEmpty { onElapsed(due) }
    }

    private static func cause(
        _ cancel: CancelCondition,
        signal: RuleSignal,
        waitScreen: String
    ) -> WaitCancelCause? {
        switch cancel {
        case .onSignal(let match):
            guard RuleEvaluator.matches(match, signal) else { return nil }
            if case .event = signal { return .event }
            return .screenViewed
        case .onScreenLeft(let names):
            guard case .screenViewed(let name) = signal else { return nil }
            if let names {
                return names.contains(name) ? nil : .screenLeft
            }
            return name == waitScreen ? nil : .screenLeft
        }
    }
}
