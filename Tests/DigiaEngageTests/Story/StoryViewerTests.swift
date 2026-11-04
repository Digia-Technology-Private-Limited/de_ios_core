import DigiaMediaCache
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The one story viewer (S1) as the entry points drive it: what it reports for a loop and for a
// close, how a failed video is timed (S4), and which neighbour bytes the plan warms through the
// real prefetch (S2) and when it re-plans (S9). Pages carry no URL, so nothing is fetched and a
// page's own time is the only clock; video pages use an unusable URL, which fails at open.

@MainActor
private final class ViewerRecorder: StoryViewerReporter {
    var completed = 0
    var dismissed: [Int] = []
    var shown: [Int] = []

    func onCompleted(total: Int, timeToCompleteMs: Int64) { completed += 1 }
    func onDismissed(index: Int) { dismissed.append(index) }
}

private final class CloseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class ToggleSlowNetwork: SlowNetworkSource, @unchecked Sendable {
    private let lock = NSLock()
    private var slow: Bool

    init(slow: Bool) { self.slow = slow }

    var isSlow: Bool { lock.withLock { slow } }
    func set(_ value: Bool) { lock.withLock { slow = value } }
}

extension RenderedUITests {
@MainActor
@Suite("Story viewer", .serialized, .tags(.media, .component, .inline))
struct StoryViewerTests {
    private func blank(_ type: StoryMediaType, durationMs: Int) -> StoryItemConfig {
        StoryItemConfig(type: type, url: "", duration: durationMs)
    }

    private func entry(
        _ stories: [StoryItemConfig],
        restart: Bool = false,
        reporter: ViewerRecorder,
        reportsCompletionOnLoop: Bool = true,
        dismissesOnDisappear: Bool = true,
        announcesClose: Bool = true
    ) -> StoryViewerEntry {
        StoryViewerEntry(
            stories: stories,
            startIndex: 0,
            handoffKey: nil,
            restartOnCompleted: restart,
            startMuted: true,
            defaultDurationMs: 5_000,
            reporter: reporter,
            onDismiss: {},
            onPageShown: { reporter.shown.append($0) },
            reportsCompletionOnLoop: reportsCompletionOnLoop,
            dismissesOnDisappear: dismissesOnDisappear,
            announcesClose: announcesClose
        )
    }

    private func mount<V: View>(_ view: V) -> UIWindow {
        ComponentTestHost.mount(rootView: view, size: CGSize(width: 360, height: 640)).window
    }

    /// Sleeps rather than spinning the run loop: a `Task { @MainActor }` the viewer starts (the
    /// rails' close notice) cannot run while this main-actor test holds the actor.
    private func pump(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Pumps the run loop (the viewer's tick is a main-queue timer) until `condition` holds.
    private func until(
        _ timeout: TimeInterval, _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            await pump(0.04)
        }
        return await condition()
    }

    // Fails if a loop is reported where the entry's funnel does not count one, or not reported
    // where it does: the `entry.restartOnCompleted, !entry.reportsCompletionOnLoop` arm in
    // `next` (inline restarts through `showPage(0)`; canvas and floater go through
    // `session.advance()`, which reports Completed once and restarts).
    @Test("a looping story reports Completed once only for the entries whose funnel counts a loop",
          arguments: [true, false])
    func loopReporting(reportsCompletionOnLoop: Bool) async {
        let reporter = ViewerRecorder()
        let window = mount(StoryViewer(
            entry: entry(
                [blank(.image, durationMs: 100), blank(.image, durationMs: 100)],
                restart: true, reporter: reporter,
                reportsCompletionOnLoop: reportsCompletionOnLoop)
        ) { _ in EmptyView() })
        defer { ComponentTestHost.unmount(window) }

        // 0, 1, then round again: 0, 1.
        #expect(await until(4) { reporter.shown.count >= 4 })

        #expect(Array(reporter.shown.prefix(4)) == [0, 1, 0, 1])
        #expect(reporter.completed == (reportsCompletionOnLoop ? 1 : 0))
    }

    // Fails if closing is reported by the wrong entries: the `entry.dismissesOnDisappear` and
    // `entry.announcesClose` tests in `onDisappear` (the floater reports its own close and has
    // no rails, so it must neither double-report nor tell rails to remount).
    @Test("unmounting before the end is a dismissal and tells the rails, for the entries that own that",
          arguments: [true, false])
    func closing(ownsClose: Bool) async {
        let reporter = ViewerRecorder()
        let counter = CloseCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .storyViewerDidClose, object: nil, queue: nil
        ) { _ in counter.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        let window = mount(StoryViewer(
            entry: entry(
                [blank(.image, durationMs: 60_000), blank(.image, durationMs: 60_000)],
                reporter: reporter,
                dismissesOnDisappear: ownsClose, announcesClose: ownsClose)
        ) { _ in EmptyView() })
        ComponentTestHost.drainRunLoop(for: 0.1)
        ComponentTestHost.unmount(window)
        // The rails are told on a later turn than the dismissal.
        _ = await until(2) { counter.count == 1 }
        await pump(0.2)

        #expect(reporter.dismissed == (ownsClose ? [0] : []))
        #expect(counter.count == (ownsClose ? 1 : 0))
    }

    // Fails if a failed video is skipped at once: `giveUpOnVideo` must start the page's own
    // time instead of calling `next()`. Fails if a failure at the moment the page opens never
    // reaches the viewer: the `if video.gaveUp { onFailed() }` in `VideoStoryPage.onAppear`
    // (the page would wait for a first frame forever).
    @Test("a video that fails as its page opens shows its still for the page's time, then moves on")
    func failedVideoRunsThePageTime() async {
        let reporter = ViewerRecorder()
        let window = mount(StoryViewer(
            entry: entry(
                [blank(.video, durationMs: 600), blank(.image, durationMs: 60_000)],
                reporter: reporter)
        ) { _ in EmptyView() })
        defer { ComponentTestHost.unmount(window) }

        ComponentTestHost.drainRunLoop(for: 0.25)
        #expect(reporter.shown == [0], "not skipped the moment it failed")

        #expect(await until(3) { reporter.shown == [0, 1] }, "moves on once its own time is up")
    }

    private func warmRig() async -> (services: MediaServices, fake: FakeRangeFetchClient, urls: [String]) {
        let fake = FakeRangeFetchClient()
        let urls = (1...2).map { "https://story-viewer.invalid/\(UUID().uuidString)/\($0).mp4" }
        for url in urls {
            await fake.setBehavior(
                url: URL(string: url)!, body: Data(repeating: 0x5A, count: 4_096))
        }
        let store = MediaRangeCacheStore(
            folder: FileManager.default.temporaryDirectory
                .appendingPathComponent("digia-story-viewer-\(UUID().uuidString)"),
            client: fake)
        var services = MediaServices.unconfigured
        services.store = { store }
        return (services, fake, urls)
    }

    private func warmStories(_ urls: [String]) -> [StoryItemConfig] {
        [
            blank(.image, durationMs: 600_000),
            StoryItemConfig(type: .video, url: urls[0], duration: 600_000),
            StoryItemConfig(type: .video, url: urls[1], duration: 600_000),
        ]
    }

    // Fails if neighbour bytes are not warmed in production: the `DefaultMediaPrefetch(...)` the
    // viewer builds its driver with (a `NoopMediaPrefetch` warms nothing, so the fake origin
    // is never asked). On an unmetered path the plan at the first page warms the first bytes of
    // the page two ahead.
    @Test("the plan warms neighbour bytes through the real prefetch")
    func neighbourBytesAreWarmed() async {
        let rig = await warmRig()
        let reporter = ViewerRecorder()
        let window = mount(
            StoryViewer(entry: entry(warmStories(rig.urls), reporter: reporter)) { _ in EmptyView() }
                .environment(\.mediaServices, rig.services)
                .environment(\.storySlowNetwork, ToggleSlowNetwork(slow: false))
        )
        defer { ComponentTestHost.unmount(window) }

        #expect(await until(5) { await rig.fake.callCount() >= 1 })
        let ranges = await rig.fake.recordedRanges()
        #expect(ranges.contains(0..<Int64(storyFirstBytes)))
    }

    // Fails if the plan is not recomputed when the network flips: the
    // `slowSource().isSlow != plannedSlow` check in `tick`. Slow plans warm only the page
    // right after the current one; once the link is fast again the page two ahead joins.
    @Test("the plan is recomputed when the slow verdict flips")
    func planFollowsTheSlowVerdict() async {
        let rig = await warmRig()
        let slow = ToggleSlowNetwork(slow: true)
        let reporter = ViewerRecorder()
        let window = mount(
            StoryViewer(entry: entry(warmStories(rig.urls), reporter: reporter)) { _ in EmptyView() }
                .environment(\.mediaServices, rig.services)
                .environment(\.storySlowNetwork, slow)
        )
        defer { ComponentTestHost.unmount(window) }

        let first = URL(string: rig.urls[0])!
        let second = URL(string: rig.urls[1])!
        #expect(await until(5) { await rig.fake.recordedURLs().contains(first) }, "slow: the next page")
        await pump(0.3)
        #expect(await !rig.fake.recordedURLs().contains(second), "slow: nothing two ahead")

        slow.set(false)
        #expect(await until(5) { await rig.fake.recordedURLs().contains(second) },
                "fast: the page two ahead joins")
    }
}
}
