import Foundation

/// A page's clock (S8): time accrues from the measured gap between ticks on a monotonic clock,
/// never from a count of nominal ticks, so a dropped or late tick costs nothing and an
/// early one adds nothing. A stretch that does not run (held, backgrounded, loading) is not
/// counted, and counting resumes from where it stopped. Mirrors Android's elapsed-realtime loop.
struct StoryPageTimer: Equatable {
    private(set) var elapsed: TimeInterval = 0
    /// The clock reading the previous tick measured from; nil while stopped.
    private var lastTick: TimeInterval?

    /// Starts again from zero. `now` is the clock reading the next gap is measured from.
    mutating func reset(now: TimeInterval? = nil) {
        elapsed = 0
        lastTick = now
    }

    /// One tick at clock reading `now`. Adds the gap since the previous tick when `running`;
    /// otherwise adds nothing and drops the baseline, so the stopped stretch is never counted.
    mutating func tick(now: TimeInterval, running: Bool) {
        defer { lastTick = running ? now : nil }
        guard running, let lastTick else { return }
        elapsed += max(0, now - lastTick)
    }

    /// The monotonic clock the viewer reads.
    static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
