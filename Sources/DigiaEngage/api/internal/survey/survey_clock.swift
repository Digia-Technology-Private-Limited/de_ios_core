import Foundation

// The survey's time, behind a test seam so a test clock drives it: the
// testkit/sdk-tests `advanceTime` moves the start delay, the 250 ms
// auto-advance, the timer countdown, and every "now" the survey reports
// (time_to_answer_ms, time_to_complete_ms, the submission's durationMs and
// occurredAt). Both seams are nil in a shipped app: the wall clock and a plain
// `Task.sleep`. Mirrors Flutter `survey_clock.dart`.
enum SurveyClock {
    /// Test-only. nil (always, in a shipped app) reads the wall clock.
    nonisolated(unsafe) static var nowForTesting: (@Sendable () -> Date)?

    /// Test-only. nil (always, in a shipped app) sleeps on the real clock.
    nonisolated(unsafe) static var sleepForTesting: (@Sendable (UInt64) async throws -> Void)?

    /// Test-only override for the survey dialog backdrop arming delay (default 350 ms).
    /// Always nil in a shipped app.
    nonisolated(unsafe) static var backdropArmDelayNsForTesting: UInt64?

    /// Now, as the survey reads it.
    static func now() -> Date { nowForTesting?() ?? Date() }

    /// A survey wait (start delay, auto-advance, timer tick). Throws
    /// `CancellationError` when its task is cancelled, as `Task.sleep` does.
    static func sleep(nanoseconds: UInt64) async throws {
        if let sleep = sleepForTesting {
            try await sleep(nanoseconds)
        } else {
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    }
}
