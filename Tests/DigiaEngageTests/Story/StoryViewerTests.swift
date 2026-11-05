import Foundation
import Testing

@testable import DigiaEngage

// The one viewer's rules (T8) that need no screen: a page's time (`StoryPageClock`, on a fake
// monotonic clock), how long an image page lasts, where a page's video starts
// (`StoryViewerSession.startMs`, N9) and what the session reports.

@MainActor
private final class RecordingReporter: StoryViewerReporter {
    var completed: [Int] = []
    var dismissed: [Int] = []

    func onCompleted(total: Int, timeToCompleteMs: Int64) { completed.append(total) }
    func onDismissed(index: Int) { dismissed.append(index) }
}

@MainActor
@Suite("Story viewer", .tags(.inline, .media, .unit))
struct StoryViewerTests {
    private static func video(_ duration: Int? = nil) -> StoryItemConfig {
        StoryItemConfig(type: .video, url: "https://viewer.test/v.mp4", duration: duration)
    }

    private static func image(_ duration: Int? = nil) -> StoryItemConfig {
        StoryItemConfig(type: .image, url: "https://viewer.test/i.jpg", duration: duration)
    }

    private func session(
        _ stories: [StoryItemConfig], restart: Bool = false, completionOnLoop: Bool = true,
        reporter: RecordingReporter = RecordingReporter(), onDismiss: @escaping @MainActor () -> Void = {}
    ) -> StoryViewerSession {
        StoryViewerSession(
            stories: stories, startIndex: 0, restartOnCompleted: restart,
            reportsCompletionOnLoop: completionOnLoop, startMuted: false, reporter: reporter,
            now: 0, onDismiss: onDismiss)
    }

    /// Ticks `clock` every 50 ms from `from` to `to`; the time the page ended, or nil.
    private func run(
        _ clock: inout StoryPageClock, from: TimeInterval, to: TimeInterval, running: Bool = true
    ) -> TimeInterval? {
        var now = from
        while now < to - 0.0001 {
            now += 0.05
            if clock.tick(now: now, running: running) { return now }
        }
        return nil
    }

    // MARK: Page time

    // Guards `clock.giveUp(now:)` taking over from the playhead: `runsOwnTime`'s `|| gaveUp` in
    // `StoryPageClock` (a failed video would otherwise wait for a playhead that never moves).
    @Test("a video page that fails shows its still for its own time, then moves on")
    func failedVideoRunsItsOwnTime() {
        var clock = StoryPageClock(isVideo: true, duration: 3, now: 0)
        #expect(run(&clock, from: 0, to: 20) == nil, "a video page waits on its playhead")

        clock.giveUp(now: 20)
        #expect(clock.runsOwnTime)
        #expect(run(&clock, from: 20, to: 22.9) == nil)
        let ended = run(&clock, from: 22.9, to: 24)
        #expect(ended.map { abs($0 - 23) < 0.06 } == true, "the page's own 3 s, counted from the failure")
    }

    // Guards `if stallTimer.elapsed >= Self.stallLimit { giveUp(now: now) }` and the
    // `playerPlaying` gate in `StoryPageClock.tick`.
    @Test("a video page whose playhead stalls is given up on, but not while it buffers or is paused")
    func stalledVideoGivesUp() {
        var clock = StoryPageClock(isVideo: true, duration: 2, now: 0)
        clock.videoFirstFrame()
        clock.videoMoved(to: 0.1)
        // Buffering, or paused by an audio interruption: the player is not playing.
        clock.playerPlaying = false
        _ = run(&clock, from: 0, to: 15)
        #expect(!clock.gaveUp, "a player that is not playing has not stalled")

        clock.playerPlaying = true
        _ = run(&clock, from: 15, to: 24.9)
        #expect(!clock.gaveUp)
        _ = run(&clock, from: 24.9, to: 25.1)
        #expect(clock.gaveUp, "10 s playing without the playhead moving")
    }

    // Guards `let ms = item?.duration ?? defaultMs` in `storyPageDurationSeconds`.
    @Test("an image page lasts its own duration when authored, else the campaign default")
    func imagePageDuration() {
        #expect(storyPageDurationSeconds(item: Self.image(2_000), defaultMs: 5_000) == 2)
        #expect(storyPageDurationSeconds(item: Self.image(nil), defaultMs: 5_000) == 5)
        #expect(storyPageDurationSeconds(item: Self.image(nil), defaultMs: 0) == nil, "a zero time moves on at once")
    }

    // Guards `StoryPageTimer.tick`: `elapsed += max(0, now - lastTick)` (the gap on the clock, so
    // a late tick costs nothing) and `guard running, let lastTick` (a held stretch adds nothing).
    @Test("a page's time follows the monotonic clock and resumes where it stopped")
    func timeFollowsTheClockAndResumes() {
        var clock = StoryPageClock(isVideo: false, duration: 5, now: 100)
        let t1 = clock.tick(now: 102, running: true)
        #expect(!t1, "one late tick still counts its 2 s")
        #expect(abs(clock.pageTimer.elapsed - 2) < 0.0001)

        // Held for 30 s: nothing counts.
        let t2 = clock.tick(now: 110, running: false)
        #expect(!t2)
        let t3 = clock.tick(now: 132, running: false)
        #expect(!t3)
        #expect(abs(clock.pageTimer.elapsed - 2) < 0.0001)

        // Let go: it carries on from 2 s, not from 0 and not from 32.
        let t4 = clock.tick(now: 132.05, running: true)
        #expect(!t4)
        let t5 = clock.tick(now: 134.9, running: true)
        #expect(!t5)
        let t6 = clock.tick(now: 135.1, running: true)
        #expect(t6)
    }

    // MARK: Where a video starts

    // Guards `leftIndices.contains(index)` in `StoryViewerSession.startMs`.
    @Test("swiping back to a video page resumes it where it was left (N9)")
    func swipeBackResumes() {
        let session = session([Self.video(), Self.video(), Self.video()])
        #expect(session.startMs(for: 0) == 0, "a first showing starts from the top")
        #expect(session.startMs(for: 1) == 0)

        session.advance(now: 1)
        session.goBack()

        #expect(session.currentIndex == 0)
        #expect(session.startMs(for: 0) == nil, "the page left mid-play resumes its playhead")
    }

    // Guards `!endedIndices.contains(index)` and `replayedIndex != index` in `startMs`.
    @Test("a page whose video ended, or a replayed page, starts from the top again")
    func endedOrReplayedStartsAtZero() {
        let session = session([Self.video(), Self.video()])
        session.videoEnded(now: 1)
        session.goBack()
        #expect(session.startMs(for: 0) == 0, "its video ran to the end")

        let other = self.session([Self.video(), Self.video()])
        other.advance(now: 1)
        other.goBack()
        other.goBack()
        #expect(other.currentIndex == 0)
        #expect(other.startMs(for: 0) == 0, "going back on the first page replays it")
    }

    // Guards `loopToFirstPage`'s `replayedIndex = 0` in `StoryViewerSession` (V8-02): tapping on
    // from page 0 left it mid-play, and the loop's wrap back to it starts it from the top, as on
    // `main`, on the canvas/floater loop and the inline one alike.
    @Test("the loop's wrap starts the first page from 0 even though a tap left it mid-play")
    func wrapRestartsTheFirstPageAtZero() {
        for completionOnLoop in [true, false] {
            let session = session(
                [Self.video(), Self.video()], restart: true, completionOnLoop: completionOnLoop)
            session.advance(now: 1)
            #expect(session.currentIndex == 1)
            session.advance(now: 2)

            #expect(session.currentIndex == 0)
            #expect(session.startMs(for: 0) == 0, "completionOnLoop \(completionOnLoop)")
        }
    }

    // Guards `replayedIndex = next` and `replayTick &+= 1` in `showPage`'s same-page branch
    // (Z8-02): a one-page story that restarts remounts its page and starts it from 0.
    @Test("a one-page story that restarts remounts its page and plays it from 0")
    func onePageRestartReplays() {
        let session = session([Self.video()], restart: true, completionOnLoop: false)
        let tick = session.replayTick

        session.advance(now: 1)

        #expect(session.currentIndex == 0)
        #expect(session.replayTick == tick + 1, "the page is mounted again")
        #expect(session.startMs(for: 0) == 0)
    }

    // Guards `replayTick &+= 1` in `goBack`'s first-page branch (Z8-01): back from page 0
    // remounts it and plays it from 0, never frozen where it was.
    @Test("going back from the first page remounts it and plays it from 0")
    func backFromTheFirstPageReplays() {
        let session = session([Self.video(), Self.video()])
        let tick = session.replayTick

        session.goBack()

        #expect(session.currentIndex == 0)
        #expect(session.replayTick == tick + 1)
        #expect(session.startMs(for: 0) == 0)
    }

    // MARK: What the session reports

    // Guards `restartOnCompleted, !reportsCompletionOnLoop` in `StoryViewerSession.advance` (inline
    // loops without reporting, as on `main`) and the `isCompleted` guard (canvas reports once).
    @Test("a looping story reports completion once on canvas and never on inline, as on main")
    func loopCompletion() {
        let canvas = RecordingReporter()
        let canvasSession = session([Self.image(), Self.image()], restart: true, reporter: canvas)
        for _ in 0..<6 { canvasSession.advance(now: 1) }
        #expect(canvas.completed == [2])
        #expect(canvasSession.currentIndex == 0)

        let inline = RecordingReporter()
        let inlineSession = session([Self.image(), Self.image()], restart: true, completionOnLoop: false, reporter: inline)
        for _ in 0..<6 { inlineSession.advance(now: 1) }
        #expect(inline.completed.isEmpty)
    }

    // Guards `if !isCompleted { reporter.onDismissed(...) }` in `reportDismissalIfOpen`.
    @Test("closing before the end reports the page left on, closing after the end reports nothing")
    func dismissal() {
        let reporter = RecordingReporter()
        var closed = 0
        let open = session([Self.image(), Self.image()], reporter: reporter, onDismiss: { closed += 1 })
        open.advance(now: 1)
        open.dismiss()
        #expect(reporter.dismissed == [1])

        let done = RecordingReporter()
        let finished = session([Self.image()], reporter: done, onDismiss: { closed += 1 })
        finished.advance(now: 1)
        finished.dismiss()
        #expect(done.completed == [1])
        #expect(done.dismissed.isEmpty)
        #expect(closed == 3)
    }
}
