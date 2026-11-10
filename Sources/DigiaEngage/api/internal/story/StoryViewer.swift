import AVFoundation
import Foundation
import SwiftUI
import UIKit

// The one full-screen story viewer (T8): inline, canvas and floater all open this view. An entry
// point passes only the stories, the start index, its reporter, the rail's handover and its
// chrome; how a page is timed, navigated, held, borrowed and planned is the viewer's alone.
// Mirrors Android `StoryViewer` and `StoryViewerSession`.

/// What the viewer reports. The entry points translate these into their own analytics: the
/// classic story events for inline, canvas interactions for canvas and floater.
@MainActor
protocol StoryViewerReporter {
    func onCompleted(total: Int, timeToCompleteMs: Int64)
    func onDismissed(index: Int)
}

// MARK: - Session

/// One opening of the viewer: the current page, one mute state reset to the campaign default on
/// every open, completion (reported once), and where each page's video starts.
@MainActor
final class StoryViewerSession: ObservableObject {
    let stories: [StoryItemConfig]
    let startIndex: Int
    /// The rail's key when a playing card was tapped, else nil.
    let handoffKey: String?
    let restartOnCompleted: Bool
    /// Canvas and floater report `Completed` once per showing and then loop; inline loops without
    /// reporting it, as on `main` (its funnel never counted a loop as a completion).
    let reportsCompletionOnLoop: Bool
    let reporter: StoryViewerReporter
    /// Closes the host (dialog, window, hero); the session reports first.
    let onDismiss: @MainActor () -> Void

    @Published private(set) var currentIndex: Int
    @Published var muted: Bool
    /// Remounts the current page (a replay restarts its video from 0).
    @Published private(set) var replayTick = 0

    private(set) var isCompleted = false
    private let openedAt: TimeInterval
    /// Pages left in this session: only those resume their playhead when shown again.
    private var leftIndices: Set<Int> = []
    /// Pages whose video ran to its end: shown again, they start from 0.
    private var endedIndices: Set<Int> = []
    /// The page a replay restarted, until the viewer moves on.
    private var replayedIndex: Int?
    /// The page the person just moved to (swipe, tap, auto-advance): it starts from 0 even when
    /// the pool still holds its player where it was left (OD-22). Cleared once that page is ready,
    /// so a later remount of it (a rotation) still resumes.
    private var arrivedIndex: Int?

    init(
        stories: [StoryItemConfig],
        startIndex: Int,
        handoffKey: String? = nil,
        restartOnCompleted: Bool,
        reportsCompletionOnLoop: Bool,
        startMuted: Bool,
        reporter: StoryViewerReporter,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.stories = stories
        let clamped = min(max(startIndex, 0), max(stories.count - 1, 0))
        self.startIndex = clamped
        self.handoffKey = handoffKey
        self.restartOnCompleted = restartOnCompleted
        self.reportsCompletionOnLoop = reportsCompletionOnLoop
        self.reporter = reporter
        self.onDismiss = onDismiss
        self.openedAt = now
        self.currentIndex = clamped
        self.muted = startMuted
    }

    var currentItem: StoryItemConfig? {
        stories.indices.contains(currentIndex) ? stories[currentIndex] : nil
    }

    /// The key the page at `index` borrows under: the rail's key for the page it handed over,
    /// else the campaign-namespaced story key (the same one the rail uses).
    func pageKey(index: Int, namespace: String?) -> String {
        if index == startIndex, let handoffKey { return handoffKey }
        return storyPoolKey(namespace: namespace, index: index)
    }

    /// Where the page at `index` starts its video: nil resumes the playhead the pool kept (a
    /// remount of a page left mid-play, such as a rotation, N9); 0 for a first showing (also a
    /// rail handover: the story starts from its top), a replay, a page whose video ended, or the
    /// page the person just moved to (OD-22).
    func startMs(for index: Int) -> Int64? {
        let resumes = leftIndices.contains(index) && !endedIndices.contains(index)
            && replayedIndex != index && arrivedIndex != index
        return resumes ? nil : 0
    }

    /// The page at `index` has its media up: a later remount of it may resume again.
    func pageReady(index: Int) {
        if arrivedIndex == index { arrivedIndex = nil }
    }

    func showPage(index: Int) {
        guard !stories.isEmpty else { return }
        let next = min(max(index, 0), stories.count - 1)
        if next == currentIndex {
            // The same page again (a one-page story looping): start it over.
            replayedIndex = next
            replayTick &+= 1
            return
        }
        leftIndices.insert(currentIndex)
        if replayedIndex != next { replayedIndex = nil }
        arrivedIndex = next
        currentIndex = next
    }

    /// The page's time is up, its video ended, or the person tapped on.
    func advance(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !stories.isEmpty else {
            onDismiss()
            return
        }
        if currentIndex < stories.count - 1 {
            showPage(index: currentIndex + 1)
            return
        }
        if restartOnCompleted, !reportsCompletionOnLoop {
            loopToFirstPage()
            return
        }
        // Reaching the end is the completion: at most once per showing.
        if !isCompleted {
            isCompleted = true
            reporter.onCompleted(total: stories.count, timeToCompleteMs: Int64((now - openedAt) * 1_000))
        }
        if restartOnCompleted { loopToFirstPage() } else { onDismiss() }
    }

    /// The loop's wrap from the last page to the first: page 0 starts from 0, as on `main`, also
    /// when a tap left it mid-play earlier in this session (V8-02).
    private func loopToFirstPage() {
        showPage(index: 0)
        replayedIndex = 0
    }

    /// The video on the current page ran to its end: like `advance`, and showing the page again
    /// starts it from 0, never from its end.
    func videoEnded(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        endedIndices.insert(currentIndex)
        advance(now: now)
    }

    func goBack() {
        if currentIndex > 0 {
            showPage(index: currentIndex - 1)
        } else {
            // Re-show the first page from its top.
            replayedIndex = currentIndex
            replayTick &+= 1
        }
    }

    /// Closing before the end is a dismissal; closing after the completion is not.
    func reportDismissalIfOpen() {
        if !isCompleted { reporter.onDismissed(index: currentIndex) }
    }

    func dismiss() {
        reportDismissalIfOpen()
        onDismiss()
    }
}

// MARK: - Page time

/// A page's clock: time accrues from the measured gap between ticks on a monotonic clock, never
/// from a count of nominal ticks, so a late tick costs nothing. A stretch that does not run (held,
/// backgrounded) is not counted, and counting resumes from where it stopped.
struct StoryPageTimer: Equatable {
    private(set) var elapsed: TimeInterval = 0
    private var lastTick: TimeInterval?

    mutating func reset(now: TimeInterval? = nil) {
        elapsed = 0
        lastTick = now
    }

    mutating func tick(now: TimeInterval, running: Bool) {
        defer { lastTick = running ? now : nil }
        guard running, let lastTick else { return }
        elapsed += max(0, now - lastTick)
    }

    /// The monotonic clock the viewer reads.
    static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// The page time for an image or a failed video: the item's own duration when authored, else the
/// campaign default. Nil (a non-positive time) moves on at once rather than stalling.
func storyPageDurationSeconds(item: StoryItemConfig?, defaultMs: Int) -> TimeInterval? {
    let ms = item?.duration ?? defaultMs
    guard ms > 0 else { return nil }
    return TimeInterval(ms) / 1_000
}

/// One page's timing: an image runs its own time; a video runs on its playhead until it fails,
/// stalls or loses its player, and then shows its still for the page's own time. Pure, so every
/// rule is tested on a fake clock.
struct StoryPageClock: Equatable {
    /// A video that shows no playhead movement for this long after its first frame, while its
    /// player is playing, is given up on (`main`'s 10 s inline watchdog). Buffering or a pause the
    /// player did not choose (an audio interruption) is not a stall. A stall is a transport fault,
    /// so it reports no health.
    static let stallLimit: TimeInterval = 10

    let isVideo: Bool
    /// The page's own time, nil to move on at once.
    let duration: TimeInterval?
    private(set) var pageTimer = StoryPageTimer()
    private var stallTimer = StoryPageTimer()
    private(set) var videoProgress: Double = 0
    private var lastVideoProgress: Double = 0
    private(set) var firstFrameShown = false
    private(set) var gaveUp = false
    /// The player is playing (`timeControlStatus == .playing`): only then can it stall.
    var playerPlaying = false

    init(isVideo: Bool, duration: TimeInterval?, now: TimeInterval) {
        self.isVideo = isVideo
        self.duration = duration
        pageTimer.reset(now: now)
    }

    /// Whether the page runs its own time: an image, or a video that gave up.
    var runsOwnTime: Bool { !isVideo || gaveUp }

    var progress: Double {
        guard runsOwnTime else { return min(max(videoProgress, 0), 1) }
        guard let duration else { return 1 }
        return min(max(pageTimer.elapsed / duration, 0), 1)
    }

    mutating func videoFirstFrame() { firstFrameShown = true }

    mutating func videoMoved(to fraction: Double) {
        guard fraction.isFinite else { return }
        videoProgress = fraction
    }

    /// The video failed, stalled or lost its player: its still shows and the page's own time
    /// starts now.
    mutating func giveUp(now: TimeInterval) {
        guard isVideo, !gaveUp else { return }
        gaveUp = true
        pageTimer.reset(now: now)
    }

    /// One tick. True when the page is over.
    mutating func tick(now: TimeInterval, running: Bool) -> Bool {
        if !runsOwnTime {
            if videoProgress > lastVideoProgress + 0.0001 {
                lastVideoProgress = videoProgress
                stallTimer.reset()
            }
            stallTimer.tick(now: now, running: running && firstFrameShown && playerPlaying)
            if stallTimer.elapsed >= Self.stallLimit { giveUp(now: now) }
            return false
        }
        pageTimer.tick(now: now, running: running)
        guard running else { return false }
        guard let duration else { return true }
        return pageTimer.elapsed >= duration
    }
}

// MARK: - Entry

/// Where a tap lands. Each entry point keeps the geometry it had on `main`.
enum StoryTapLayout: Equatable {
    /// Inline: only a strip at each edge navigates.
    case edges(width: CGFloat)
    /// Canvas and floater: the left half goes back, the right half goes on.
    case halves
}

/// What the viewer tells the chrome an entry point draws over the pages.
struct StoryViewerContext {
    let size: CGSize
    let index: Int
    let count: Int
    let item: StoryItemConfig
    /// 0...1, the current page's progress.
    let progress: Double
    let muted: Bool
    let toggleMute: @MainActor () -> Void
    /// Closes the viewer as the person leaving: a dismissal unless the story completed.
    let dismiss: @MainActor () -> Void
}

/// Everything an entry point hands the viewer.
struct StoryViewerEntry {
    var stories: [StoryItemConfig]
    var startIndex: Int
    /// The rail's handover when a playing card was tapped, else nil.
    var handover: StoryHandover?
    var restartOnCompleted: Bool
    var startMuted: Bool
    /// The page time for an image or a failed video that sets none of its own.
    var defaultDurationMs: Int
    var reporter: StoryViewerReporter
    var onDismiss: @MainActor () -> Void
    /// A page became visible (on open and on every change of page).
    var onPageShown: @MainActor (Int) -> Void = { _ in }
    var tapLayout: StoryTapLayout = .halves
    /// False while the host animates the viewer (the floater's hero): no taps, no holds.
    var navigationEnabled = true
    var reportsCompletionOnLoop = true
    /// Whether the viewer going away before the end reports a dismissal (inline, torn down by its
    /// host from anywhere). Canvas and floater report only from their own close, as on `main`.
    var dismissesOnDisappear = false
    /// What a video page's letterbox shows after the first frame: black, but the inline story
    /// passes #1A1A1A as on `main` (OD-18).
    var videoGroundAfterFirstFrame: Color = .black
}

// MARK: - Viewer

@MainActor
struct StoryViewer<Chrome: View>: View {
    let entry: StoryViewerEntry
    let chrome: (StoryViewerContext) -> Chrome

    @StateObject private var session: StoryViewerSession
    @State private var clock: StoryPageClock
    @State private var player: (index: Int, player: AVPlayer)?
    @State private var applicationActive = UIApplication.shared.applicationState == .active
    @State private var held = false
    @State private var driver: StoryPlanDriver?
    @State private var plannedSlow = false
    @State private var lastShownIndex: Int?
    @GestureState private var holding = false

    @Environment(\.mediaServices) private var mediaServices
    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.storySlowNetwork) private var slowOverride

    init(entry: StoryViewerEntry, @ViewBuilder chrome: @escaping (StoryViewerContext) -> Chrome) {
        self.entry = entry
        self.chrome = chrome
        let session = StoryViewerSession(
            stories: entry.stories,
            startIndex: entry.startIndex,
            handoffKey: entry.handover?.key,
            restartOnCompleted: entry.restartOnCompleted,
            reportsCompletionOnLoop: entry.reportsCompletionOnLoop,
            startMuted: entry.startMuted,
            reporter: entry.reporter,
            onDismiss: entry.onDismiss
        )
        _session = StateObject(wrappedValue: session)
        _clock = State(initialValue: Self.pageClock(for: session.currentItem, defaultMs: entry.defaultDurationMs))
    }

    private static func pageClock(for item: StoryItemConfig?, defaultMs: Int) -> StoryPageClock {
        StoryPageClock(
            isVideo: item?.type == .video,
            duration: storyPageDurationSeconds(item: item, defaultMs: defaultMs),
            now: StoryPageTimer.clock
        )
    }

    private var running: Bool { applicationActive && !held }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if let item = session.currentItem {
                    page(item: item, index: session.currentIndex)
                        .id("\(session.currentIndex)-\(session.replayTick)")
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    navigationLayer
                        .allowsHitTesting(entry.navigationEnabled)
                        .accessibilityHidden(!entry.navigationEnabled)

                    chrome(StoryViewerContext(
                        size: proxy.size,
                        index: session.currentIndex,
                        count: session.stories.count,
                        item: item,
                        progress: clock.progress,
                        muted: session.muted,
                        toggleMute: { session.muted.toggle() },
                        dismiss: { session.dismiss() }
                    ))
                }
            }
        }
        .ignoresSafeArea()
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in tick() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            applicationActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            applicationActive = true
        }
        .onChange(of: holding) { held = $0 }
        .onAppear {
            pageShown(session.currentIndex)
            drivePlan()
        }
        .onDisappear {
            driver?.cancelAll()
            entry.handover?.release()
            if entry.dismissesOnDisappear { session.reportDismissalIfOpen() }
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func page(item: StoryItemConfig, index: Int) -> some View {
        if item.type == .video {
            VideoStoryPage(
                item: item,
                pageKey: session.pageKey(index: index, namespace: campaignKey),
                muted: session.muted,
                playing: running,
                startMs: session.startMs(for: index),
                groundAfterFirstFrame: entry.videoGroundAfterFirstFrame,
                onReady: { ready in
                    guard index == session.currentIndex else { return }
                    session.pageReady(index: index)
                    player = (index, ready)
                    clock.videoFirstFrame()
                    pageHoldsItsPlayer()
                },
                onEnded: {
                    guard index == session.currentIndex else { return }
                    navigate { session.videoEnded() }
                },
                onFailure: { giveUp(index) },
                onLost: { giveUp(index) }
            )
        } else {
            ImageStoryPage(item: item) {}
        }
    }

    // MARK: Navigation

    private var navigationLayer: some View {
        ZStack {
            // The whole frame is the hold target, tap strips or not.
            Color.clear.contentShape(Rectangle())
            switch entry.tapLayout {
            case let .edges(width):
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).frame(width: width).onTapGesture { previous() }
                    Spacer(minLength: 0)
                    Color.clear.contentShape(Rectangle()).frame(width: width).onTapGesture { next() }
                }
            case .halves:
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { previous() }
                    Color.clear.contentShape(Rectangle()).onTapGesture { next() }
                }
            }
        }
        // Held until the finger lifts (the drag half of the sequence), not just until the
        // long-press threshold. Simultaneous, so the taps keep working.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.2)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .updating($holding) { value, state, _ in
                    if case .second = value { state = true }
                }
        )
    }

    private func next() { navigate { session.advance() } }

    private func previous() { navigate { session.goBack() } }

    /// Runs a session move, and when it changed the page, starts the new one: the page left is
    /// paused where it is (its player may stay held for a swipe back), its clock is replaced and
    /// the plan recomputed.
    private func navigate(_ move: () -> Void) {
        let before = (session.currentIndex, session.replayTick)
        move()
        guard before != (session.currentIndex, session.replayTick) else { return }
        player?.player.pause()
        player = nil
        clock = Self.pageClock(for: session.currentItem, defaultMs: entry.defaultDurationMs)
        drivePlan()
        pageShown(session.currentIndex)
    }

    private func pageShown(_ index: Int) {
        guard lastShownIndex != index else { return }
        lastShownIndex = index
        entry.onPageShown(index)
    }

    // MARK: Timing

    private func tick() {
        // The network got slower or faster (or a warm measured it): re-plan the window.
        if slowSource().isSlow != plannedSlow { drivePlan() }
        guard session.currentItem != nil else { return }
        if !clock.runsOwnTime, let current = player, current.index == session.currentIndex {
            let item = current.player.currentItem
            let duration = item?.duration.seconds ?? 0
            if duration.isFinite, duration > 0 {
                clock.videoMoved(to: current.player.currentTime().seconds / duration)
            }
            clock.playerPlaying = current.player.timeControlStatus == .playing
        }
        if clock.tick(now: StoryPageTimer.clock, running: running) { next() }
    }

    /// The current video cannot play (it failed, or lost its player): its still stays and the
    /// page's own time starts now, then the story moves on.
    private func giveUp(_ index: Int) {
        guard index == session.currentIndex else { return }
        player = nil
        clock.giveUp(now: StoryPageTimer.clock)
        pageHoldsItsPlayer()
    }

    /// The current page has its player (or gave up on it): the rail's handover hold is done, and
    /// neighbour work may start.
    private func pageHoldsItsPlayer() {
        entry.handover?.release()
        drivePlan()
    }

    // MARK: Download plan

    private func drivePlan() {
        let stories = session.stories
        guard !stories.isEmpty else { return }
        let index = session.currentIndex
        let slow = slowSource().isSlow
        plannedSlow = slow
        let firstFrameShown = clock.runsOwnTime || clock.firstFrameShown
        let namespace = campaignKey
        let session = session
        planDriver().update(
            actions: StoryDownloadPlan.plan(
                stories: stories.map { StoryDownloadPlan.Item(isVideo: $0.type == .video) },
                currentIndex: index,
                firstFrameShown: firstFrameShown,
                slowNetwork: slow
            ),
            urlOf: { stories[$0].url },
            isVideoOf: { stories[$0].type == .video },
            keyOf: { session.pageKey(index: $0, namespace: namespace) },
            // Until the new page's first frame the plan names only that page; the pages either
            // side keep the players they hold. After it, the plan alone decides (a slow network
            // drops the next page's player).
            keepPlayersFor: firstFrameShown ? [] : [index - 1, index + 1]
        )
    }

    private func planDriver() -> StoryPlanDriver {
        if let driver { return driver }
        let source = slowSource()
        let created = StoryPlanDriver(
            pool: mediaServices.videoPool,
            warm: { [mediaServices] url, kind, bytes in
                await MediaPrefetch.warm(url, kind: kind, bytes: bytes, services: mediaServices)
            },
            onWarm: { bytes, elapsed in source.noteWarm(bytes: bytes, elapsed: elapsed) }
        )
        driver = created
        return created
    }

    private func slowSource() -> any SlowNetworkSource {
        slowOverride ?? PathSlowNetworkSource.shared
    }
}

private struct StorySlowNetworkKey: EnvironmentKey {
    static let defaultValue: (any SlowNetworkSource)? = nil
}

extension EnvironmentValues {
    /// Replaces the process's slow-network source for the viewers below (tests).
    var storySlowNetwork: (any SlowNetworkSource)? {
        get { self[StorySlowNetworkKey.self] }
        set { self[StorySlowNetworkKey.self] = newValue }
    }
}
