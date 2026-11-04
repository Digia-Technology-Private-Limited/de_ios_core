import Foundation
import Testing

@testable import DigiaEngage

// StoryViewer session (T10): one mute state per session reset on every open, keys keyed on the
// opening (never the current index), zero-duration pages degrading forward. Mirrors Android
// `StoryViewerSession` + the R-P3-03/R-P3-04 behaviours.

@MainActor
private final class FakeStoryReporter: StoryViewerReporter {
    var completed: [(total: Int, timeToCompleteMs: Int64)] = []
    var dismissed: [Int] = []

    func onCompleted(total: Int, timeToCompleteMs: Int64) {
        completed.append((total, timeToCompleteMs))
    }

    func onDismissed(index: Int) {
        dismissed.append(index)
    }
}

@MainActor
private func storyItems(_ count: Int) -> [StoryItemConfig] {
    (0..<count).map { i in
        StoryItemConfig(type: .image, url: "https://media.test/\(i).png", duration: 5_000)
    }
}

@MainActor
private func session(
    count: Int = 3,
    startIndex: Int = 0,
    handoffKey: String? = nil,
    restart: Bool = false,
    startMuted: Bool = false,
    reporter: FakeStoryReporter? = nil
) -> (StoryViewerSession, FakeStoryReporter) {
    let fake = reporter ?? FakeStoryReporter()
    let s = StoryViewerSession(
        stories: storyItems(count),
        startIndex: startIndex,
        handoffKey: handoffKey,
        restartOnCompleted: restart,
        startMuted: startMuted,
        reporter: fake,
        onDismiss: {}
    )
    return (s, fake)
}

@Suite("StoryViewerSession", .tags(.media, .unit, .inline))
@MainActor
struct StoryViewerSessionTests {
    // Fails if mute is not per-session: the `muted = startMuted` reset in `init`. A previous
    // viewer's choice must never carry over to a new open (story 11).
    @Test("each open starts with the campaign default sound")
    func eachOpenStartsWithTheCampaignDefaultSound() {
        let (first, _) = session(startMuted: false)
        #expect(!first.muted)
        first.muted = true

        let (second, _) = session(startMuted: false)
        #expect(!second.muted)
        #expect(first.openToken != second.openToken)
    }

    // Fails if the handover key is not honoured for the start page only: the
    // `index == currentIndex && index == startIndex` arm of `pageKey` (R-P3-04). The token is
    // deliberately distinct from the namespaced form so the test pins WHEN it applies.
    @Test("the start page borrows the handoff key, others namespace by campaign")
    func startPageBorrowsTheHandoffKey() {
        let (s, _) = session(startIndex: 1, handoffKey: "rail-transfer-token")
        #expect(s.pageKey(index: 1, namespace: "test") == "rail-transfer-token")
        #expect(s.pageKey(index: 0, namespace: "test") == "test/story-0")
        #expect(s.pageKey(index: 2, namespace: "test") == "test/story-2")

        s.showPage(index: 2)
        // Swiped away: the start page's handover no longer applies on a return visit.
        #expect(s.pageKey(index: 1, namespace: "test") == "test/story-1")
    }

    // Fails if a reopen shares identity: `openToken` is minted per `init`, never derived.
    @Test("sessions key on the open token, never the content")
    func sessionsKeyOnTheOpenToken() {
        let (a, _) = session()
        let (b, _) = session()
        #expect(a.openToken != b.openToken)
    }

    // Fails if swiping leaves the session: `currentIndex` is the session's own state, so mute
    // and the completion guard survive navigation (R-P3-04).
    @Test("swiping stays inside the session")
    func swipingStaysInsideTheSession() {
        let (s, fake) = session()
        s.muted = true
        s.showPage(index: 1)
        #expect(s.muted)
        #expect(s.currentIndex == 1)
        #expect(fake.completed.isEmpty)
    }

    // Fails if completion repeats: the `completedReported` guard in `advance`.
    @Test("reaching the end completes once, then dismisses")
    func reachingTheEndCompletesOnce() {
        let (s, fake) = session(count: 2, restart: true)
        s.showPage(index: 1)
        s.advance()
        #expect(fake.completed.count == 1)
        #expect(fake.completed[0].total == 2)
        #expect(s.currentIndex == 0)
        // A second lap reports nothing more.
        s.showPage(index: 1)
        s.advance()
        #expect(fake.completed.count == 1)
        #expect(fake.dismissed.isEmpty)
    }

    // Fails if closing before the end is not a dismissal: `dismiss` reports unless the
    // completion already went out.
    @Test("closing before the end reports the frame left on")
    func closingBeforeTheEndReportsDismissal() {
        let (s, fake) = session()
        s.showPage(index: 1)
        s.dismiss()
        #expect(fake.dismissed == [1])
    }

    // Fails if going back from the first frame does not replay: the `replayTick` bump in
    // `goBack` remounts the page from 0.
    @Test("going back from the first frame replays it")
    func goingBackFromTheFirstFrameReplaysIt() {
        let (s, _) = session()
        #expect(s.replayTick == 0)
        s.goBack()
        #expect(s.currentIndex == 0)
        #expect(s.replayTick == 1)
        s.goBack()
        #expect(s.replayTick == 2)
    }
}

@Suite("StoryPageDuration", .tags(.media, .unit, .inline))
struct StoryPageDurationTests {
    private func image(duration: Int?) -> StoryItemConfig {
        StoryItemConfig(type: .image, url: "https://media.test/i.png", duration: duration)
    }

    // Fails if a zero-duration page stalls: the `ms > 0` degrade-forward arm of
    // `storyPageDurationSeconds` (R-P3-03) — the viewer skips the frame instead of waiting.
    @Test("a zero-duration page degrades forward")
    func zeroDurationDegradesForward() {
        #expect(storyPageDurationSeconds(item: image(duration: 0), defaultMs: 5_000) == nil)
    }

    // Fails if a negative duration is waited on: same arm, negative side.
    @Test("a negative duration degrades forward")
    func negativeDurationDegradesForward() {
        #expect(storyPageDurationSeconds(item: image(duration: -100), defaultMs: 5_000) == nil)
    }

    // Fails if the seconds conversion moves: the `Double(ms) / 1_000` line.
    @Test("a positive duration runs its own time")
    func positiveDurationRunsItsOwnTime() {
        #expect(storyPageDurationSeconds(item: image(duration: 2_500), defaultMs: 5_000) == 2.5)
        #expect(storyPageDurationSeconds(item: image(duration: nil), defaultMs: 5_000) == 5.0)
    }
}

@Suite("StorySlowSignal", .tags(.media, .unit))
struct StorySlowSignalTests {
    // Fails if the slow mapping inverts: the `isExpensive || isConstrained` line in
    // `slowNetworkFor` (D10 — the wired `NWPathMonitor` mapping in `StoryDownloadPlan.swift`,
    // consumed, never re-derived).
    @Test("an expensive or constrained path is slow")
    func expensiveOrConstrainedIsSlow() {
        #expect(slowNetworkFor(isExpensive: true, isConstrained: false))
        #expect(slowNetworkFor(isExpensive: false, isConstrained: true))
        #expect(slowNetworkFor(isExpensive: true, isConstrained: true))
        #expect(!slowNetworkFor(isExpensive: false, isConstrained: false))
    }
}
