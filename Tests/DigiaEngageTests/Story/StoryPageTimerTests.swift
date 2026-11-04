import Foundation
import Testing

@testable import DigiaEngage

// The page clock (S8): time is the measured gap between ticks, not a count of nominal ticks,
// and a stretch that does not run is not counted. Mirrors Android's elapsed-realtime loop.

@Suite("StoryPageTimer", .tags(.media, .unit, .inline))
struct StoryPageTimerTests {
    // Fails if the timer counts ticks instead of time: the `elapsed += max(0, now - lastTick)`
    // line in `tick` (a fixed `+= 0.05` reads 0.15 here, after three ticks 0.3 s apart in all).
    @Test("a late or dropped tick costs nothing: elapsed is the clock, not the tick count")
    func elapsedIsTheClockNotTheTickCount() {
        var timer = StoryPageTimer()
        timer.reset(now: 100)
        timer.tick(now: 100.05, running: true)
        timer.tick(now: 100.25, running: true)   // the main thread was busy for 0.2 s
        timer.tick(now: 100.30, running: true)

        #expect(abs(timer.elapsed - 0.30) < 1e-9)
    }

    // Fails if a held or backgrounded stretch is counted, or counting does not resume from
    // where it stopped: the `defer { lastTick = running ? now : nil }` baseline drop in `tick`
    // (without it the 5 s of hold lands in the first tick after the release).
    @Test("a stretch that does not run is not counted, and counting resumes where it stopped")
    func aStoppedStretchIsNotCounted() {
        var timer = StoryPageTimer()
        timer.reset(now: 0)
        timer.tick(now: 1, running: true)
        timer.tick(now: 3, running: false)
        timer.tick(now: 6, running: false)       // held for five seconds in all
        timer.tick(now: 6.5, running: true)      // released: the baseline is this tick
        timer.tick(now: 7.5, running: true)

        #expect(abs(timer.elapsed - 2.0) < 1e-9)
    }

    // Fails if a page opened by `reset(now:)` loses the time before its first tick: the
    // `lastTick = now` in `reset` (the first tick would then only set the baseline).
    @Test("the first tick counts from the reset, not from itself")
    func firstTickCountsFromTheReset() {
        var timer = StoryPageTimer()
        timer.reset(now: 10)
        timer.tick(now: 10.4, running: true)

        #expect(abs(timer.elapsed - 0.4) < 1e-9)
    }

    // Fails if a clock reading that goes backwards shortens the page: the `max(0, …)` guard.
    @Test("a clock that steps back never subtracts time")
    func aBackwardsClockNeverSubtracts() {
        var timer = StoryPageTimer()
        timer.reset(now: 50)
        timer.tick(now: 51, running: true)
        timer.tick(now: 50.5, running: true)

        #expect(timer.elapsed == 1)
    }
}
