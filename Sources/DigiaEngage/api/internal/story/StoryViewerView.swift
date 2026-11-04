import AVFoundation
import SwiftUI
import UIKit

// The one full-screen story viewer (issue #157 stories 25, 42): inline, canvas and floater all
// open this view. An entry point differs only in what it passes in — the stories, where to
// start, the analytics reporter, the rail's handoff key and its chrome — never in how a page is
// timed, navigated, held, borrowed or planned. Mirrors Android `StoryViewer` and Flutter
// `StoryViewer`.

/// Where a tap lands. Each entry point keeps the geometry it always had.
enum StoryTapLayout: Equatable {
    /// Inline: only the two edge strips navigate; the middle is left to the chrome.
    case edges(width: CGFloat)
    /// Canvas and floater: the left half goes back, the right half goes on.
    case halves
}

/// What the viewer tells the chrome an entry point draws over the pages.
struct StoryViewerContext {
    /// The viewer's own size (the full-bleed reader), for chrome that scales against it.
    let size: CGSize
    let index: Int
    let count: Int
    /// The current page's story.
    let item: StoryItemConfig
    /// 0...1, the current page's progress.
    let progress: Double
    let muted: Bool
    let toggleMute: @MainActor () -> Void
    /// Closes the viewer as the user leaving: reports a dismissal unless the story completed.
    let dismiss: @MainActor () -> Void
}

/// Everything an entry point hands the shared viewer.
struct StoryViewerEntry {
    var stories: [StoryItemConfig]
    var startIndex: Int
    /// The rail's transfer token when a playing thumbnail was tapped, else nil.
    var handoffKey: String?
    var restartOnCompleted: Bool
    var startMuted: Bool
    /// The page time for an image or a failed video that sets none of its own.
    var defaultDurationMs: Int
    var reporter: StoryViewerReporter
    /// Closes the host (dialog, window, hero).
    var onDismiss: @MainActor @Sendable () -> Void
    /// A page became visible (on open and on every change of page).
    var onPageShown: @MainActor (Int) -> Void = { _ in }

    var tapLayout: StoryTapLayout = .halves
    /// Margins the navigation layer keeps clear (the canvas entries keep it inside the safe region).
    var tapInsets = EdgeInsets()
    /// False while the host is animating the viewer (the floater's hero): no taps, no holds.
    var navigationEnabled = true
    /// Whether looping reports `Completed` once per showing (canvas, floater) or restarts
    /// without reporting (inline, whose funnel never counted a loop as a completion).
    var reportsCompletionOnLoop = true
    /// Whether the viewer unmounting before the end reports a dismissal (inline, canvas: they
    /// are torn down by the host closing; the floater reports from its explicit close).
    var dismissesOnDisappear = true
    /// Whether closing tells rails to remount their videos (`.storyViewerDidClose`).
    var announcesClose = true
}

/// The viewer. `chrome` draws what an entry point puts over the pages: its progress strip,
/// buttons and authored overlays. It sits above the navigation layer, so a button there wins
/// the tap.
@MainActor
struct StoryViewer<Chrome: View>: View {
    let entry: StoryViewerEntry
    let chrome: (StoryViewerContext) -> Chrome

    @StateObject private var session: StoryViewerSession

    @State private var elapsed: Double = 0
    @State private var videoProgress: Double = 0
    @State private var videoStalled: Double = 0
    @State private var lastVideoProgress: Double = 0
    @State private var videoReady = false
    /// True while the current video is buffering (waiting to play). The stall watchdog pauses
    /// while this is set so a slow network isn't mistaken for a dead video.
    @State private var videoBuffering = false
    /// The current video page failed to play: it shows its still and the page's own time runs
    /// instead (an author's picture would otherwise be skipped, a stall would hang the story).
    @State private var mediaFailed = false
    @State private var paused = false
    @State private var applicationActive = UIApplication.shared.applicationState == .active
    @State private var planDriver: StoryPlanDriver?
    @State private var firstFrameShown: Bool
    @State private var lastShownIndex: Int?
    @State private var slowSource = PathSlowNetworkSource()
    @GestureState private var holding = false

    @Environment(\.mediaServices) private var mediaServices
    @Environment(\.digiaCampaignKey) private var campaignKey

    init(
        entry: StoryViewerEntry,
        @ViewBuilder chrome: @escaping (StoryViewerContext) -> Chrome
    ) {
        self.entry = entry
        self.chrome = chrome
        let clamped = min(max(entry.startIndex, 0), max(entry.stories.count - 1, 0))
        _session = StateObject(wrappedValue: StoryViewerSession(
            stories: entry.stories,
            startIndex: clamped,
            handoffKey: entry.handoffKey,
            restartOnCompleted: entry.restartOnCompleted,
            startMuted: entry.startMuted,
            reporter: entry.reporter,
            onDismiss: entry.onDismiss
        ))
        _firstFrameShown = State(initialValue:
            entry.stories.indices.contains(clamped)
                ? entry.stories[clamped].type != .video
                : true)
    }

    private var currentIndex: Int { session.currentIndex }

    private var currentItem: StoryItemConfig? {
        session.stories.indices.contains(currentIndex) ? session.stories[currentIndex] : nil
    }

    private var currentDuration: Double {
        storyPageDurationSeconds(item: currentItem, defaultMs: entry.defaultDurationMs) ?? 0
    }

    private var progress: Double {
        if currentItem?.type == .video, !mediaFailed {
            return min(max(videoProgress, 0), 1)
        }
        return min(max(elapsed / max(currentDuration, 0.1), 0), 1)
    }

    private var planInput: String {
        "\(currentIndex)-\(firstFrameShown)-\(session.replayTick)"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                if let item = currentItem {
                    page(item: item, index: currentIndex)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    navigationLayer
                        .padding(entry.tapInsets)
                        .allowsHitTesting(entry.navigationEnabled)
                        .accessibilityHidden(!entry.navigationEnabled)

                    chrome(StoryViewerContext(
                        size: proxy.size,
                        index: currentIndex,
                        count: session.stories.count,
                        item: item,
                        progress: progress,
                        muted: session.muted,
                        toggleMute: { session.muted.toggle() },
                        dismiss: { session.dismiss() }
                    ))
                }
            }
        }
        .ignoresSafeArea()
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            tick()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification
        )) { _ in
            applicationActive = false
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            applicationActive = true
        }
        .onAppear {
            pageShown(currentIndex)
        }
        .onChange(of: holding) { paused = $0 }
        // A page is shown, then the viewer reports it: Step Viewed fires for each frame that
        // becomes visible, the first included.
        .onChange(of: currentIndex) { index in
            resetTiming()
            firstFrameShown = !(currentItem?.type == .video)
            drivePlan()
            pageShown(index)
        }
        // Any teardown before the last frame is a user dismissal (swipe / edge / ESC).
        // Completion is reported by the session first, so it reports only once there.
        .onDisappear {
            planDriver?.cancelAll()
            if entry.dismissesOnDisappear, !session.isCompleted {
                session.dismiss()
            }
            if entry.announcesClose {
                // After every holder is given back, the rail remounts and resumes.
                Task { @MainActor in
                    NotificationCenter.default.post(name: .storyViewerDidClose, object: nil)
                }
            }
        }
        .task(id: planInput) {
            drivePlan()
        }
    }

    /// Tells the entry a page became visible, once per change of page.
    private func pageShown(_ index: Int) {
        guard lastShownIndex != index else { return }
        lastShownIndex = index
        entry.onPageShown(index)
    }

    // MARK: - Pages

    @ViewBuilder
    private func page(item: StoryItemConfig, index: Int) -> some View {
        // A replay remounts the current page so its video restarts from 0.
        let pageID = "\(index)-\(session.replayTick)"
        if item.type == .video {
            VideoStoryPage(
                item: item,
                pageKey: session.pageKey(index: index, namespace: campaignKey),
                muted: session.muted,
                playing: applicationActive && !paused,
                onReady: { _ in
                    guard index == currentIndex else { return }
                    videoReady = true
                    firstFrameShown = true
                    drivePlan()
                },
                onProgress: {
                    guard index == currentIndex else { return }
                    videoProgress = $0
                },
                onEnded: {
                    guard index == currentIndex else { return }
                    next()
                },
                onBuffering: {
                    guard index == currentIndex else { return }
                    videoBuffering = $0
                },
                onFailed: {
                    guard index == currentIndex else { return }
                    mediaFailed = true
                }
            )
            .id(pageID)
        } else if !item.url.isEmpty {
            // A picture with no URL draws nothing: no spinner, no fetch, and its time still runs.
            ImageStoryPage(item: item) {
                guard index == currentIndex else { return }
                videoReady = true
                firstFrameShown = true
                drivePlan()
            }
            .id(pageID)
        }
    }

    // MARK: - Navigation

    private var navigationLayer: some View {
        ZStack {
            // The whole frame is the hold target, tap strips or not.
            Color.clear.contentShape(Rectangle())
            switch entry.tapLayout {
            case let .edges(width):
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: width)
                        .onTapGesture { previous() }
                    Spacer(minLength: 0)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: width)
                        .onTapGesture { next() }
                }
            case .halves:
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { previous() }
                    Color.clear.contentShape(Rectangle()).onTapGesture { next() }
                }
            }
        }
        // Simultaneous, so the taps above keep working. The press stays held until the finger
        // lifts (the drag half of the sequence), not just until the long-press threshold.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.2)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .updating($holding) { value, state, _ in
                    if case .second = value { state = true }
                }
        )
    }

    private func next() {
        resetTiming()
        if currentIndex < session.stories.count - 1 {
            session.showPage(index: currentIndex + 1)
        } else if entry.restartOnCompleted, !entry.reportsCompletionOnLoop {
            session.showPage(index: 0)
        } else {
            // Completion (once per showing) and restart/dismiss live in `session.advance()`:
            // never bypassed when the entry's funnel counts a loop.
            session.advance()
        }
    }

    private func previous() {
        resetTiming()
        if currentIndex == 0 {
            // Re-show the first story from the top (replayTick remounts its page).
            session.goBack()
        } else {
            session.showPage(index: currentIndex - 1)
        }
    }

    // MARK: - Timing

    private func tick() {
        guard applicationActive, !paused, let item = currentItem else { return }
        if item.type == .video, !mediaFailed {
            // File download and buffering are legitimate loading. Start the
            // watchdog only after the player has displayed its first frame.
            if !videoReady || videoBuffering { return }
            if videoProgress > lastVideoProgress + 0.0001 {
                lastVideoProgress = videoProgress
                videoStalled = 0
            } else {
                videoStalled += 0.05
                if videoStalled >= 10 { next() }
            }
            return
        }
        // A zero-duration page degrades forward instead of stalling: the frame is skipped
        // at once, never waited on.
        guard let duration = storyPageDurationSeconds(
            item: item, defaultMs: entry.defaultDurationMs) else {
            next()
            return
        }
        elapsed += 0.05
        if elapsed >= duration {
            next()
        }
    }

    private func resetTiming() {
        elapsed = 0
        videoProgress = 0
        lastVideoProgress = 0
        videoStalled = 0
        videoBuffering = false
        videoReady = false
        mediaFailed = false
    }

    // MARK: - Download plan

    private func drivePlan() {
        // Snapshots: the driver's closures are Sendable, so they take plain values, not the
        // MainActor-bound session.
        let urls = session.stories.map(\.url)
        let kinds = session.stories.map { $0.type == .video }
        let index = currentIndex
        let start = session.startIndex
        let handoff = session.handoffKey
        let namespace = campaignKey
        driver().update(
            actions: StoryDownloadPlan.plan(
                stories: kinds.map { StoryDownloadPlan.Item(isVideo: $0) },
                currentIndex: index,
                firstFrameShown: firstFrameShown,
                slowNetwork: slowSource.isSlow
            ),
            urlOf: { urls[$0] },
            isVideoOf: { kinds[$0] },
            // The pool-lease half of the plan: neighbour holders stay warm under the same
            // campaign-namespaced keys the pages borrow under, so a swipe hands over the
            // same instance.
            keyOf: { page in
                if page == index, let handoff, page == start { return handoff }
                return storyPoolKey(namespace: namespace, index: page)
            },
            pool: mediaServices.pool()
        )
    }

    private func driver() -> StoryPlanDriver {
        if let planDriver { return planDriver }
        let created = StoryPlanDriver()
        planDriver = created
        return created
    }
}
