import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct DigiaInlineStoryView: View {
    let config: InlineStoryConfig
    let payload: CEPTriggerPayload

    @ObservedObject private var overlayController = SDKInstance.shared.controller
    @State private var eligibleIndices: Set<Int> = []
    @State private var failedPlayerIdentities: [Int: StoryThumbnailPlayerIdentity] = [:]
    @State private var sequentialActiveIndex: Int?
    @State private var slotVisible = false
    @State private var applicationActive = false
    @State private var playbackRestartGeneration = 0
    @State private var latestGeometry = StoryRailGeometry()
    @State private var viewportBounds = CGRect.null
    @State private var scrollSettleTask: Task<Void, Never>?

    var body: some View {
        storyRail
    }

    private var storyRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: CGFloat(config.card.spacing)) {
                ForEach(Array(config.items.enumerated()), id: \.offset) { index, item in
                    let playerIdentity = thumbnailPlayerIdentity(item)
                    let eligible = playableIndices.contains(index)
                    let scheduled =
                        eligible
                        && (
                            config.thumbnailVideoPlayback == .simultaneous
                            || sequentialActiveIndex == index
                        )
                    StoryThumbnailCard(
                        item: item,
                        config: config,
                        failed: failedPlayerIdentities[index] == playerIdentity,
                        playbackState: ThumbnailPlaybackViewState(
                            eligible: eligible,
                            scheduled: scheduled,
                            shouldPlay: playbackAllowed && scheduled,
                            canLoad: applicationActive,
                            mode: config.thumbnailVideoPlayback,
                            playableIndices: playableIndices,
                            restartGeneration: playbackRestartGeneration
                        ),
                        onWindowCompleted: { advanceSequential(from: index) },
                        onFailed: { markFailed(index, playerIdentity: playerIdentity) }
                    )
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: StoryRailGeometryPreference.self,
                                    value: StoryRailGeometry(
                                        cards: [index: proxy.frame(in: .global)]
                                    )
                                )
                            }
                        }
                        .onTapGesture {
                            SDKInstance.shared.reportStoryOpened(payload)
                            SDKInstance.shared.controller.showStoryOverlay(
                                config: config,
                                initialIndex: index,
                                payload: payload
                            )
                        }
                }
            }
            .padding(.horizontal, CGFloat(config.card.spacing))
        }
        .background {
            ZStack {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: StoryRailGeometryPreference.self,
                        value: StoryRailGeometry(rail: proxy.frame(in: .global))
                    )
                }
                StoryViewportReader { viewport in
                    guard viewportBounds != viewport else { return }
                    viewportBounds = viewport
                    updateEligibility(
                        latestGeometry,
                        viewport: viewport,
                        restartPlayback: true
                    )
                }
            }
        }
        .onPreferenceChange(StoryRailGeometryPreference.self) { geometry in
            latestGeometry = geometry
            scheduleEligibilityAfterScroll(geometry)
        }
        .onAppear {
            applicationActive = UIApplication.shared.applicationState == .active
            Task { @MainActor in
                await Task.yield()
                updateEligibility(latestGeometry, restartPlayback: true)
            }
        }
        .onDisappear {
            scrollSettleTask?.cancel()
            scrollSettleTask = nil
        }
        .task(id: videoPrefetchIdentity) {
            await DigiaVideoFileCache.shared.prefetch(videoPrefetchURLs)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            restartEligiblePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification
        )) { _ in
            applicationActive = false
        }
        .frame(height: CGFloat(config.card.height))
    }

    private var playableIndices: Set<Int> {
        playableIndices(from: eligibleIndices)
    }

    private var videoPrefetchIdentity: [String] {
        config.items.filter { $0.type == .video }.map(\.url)
    }

    private var videoPrefetchURLs: [URL] {
        videoPrefetchIdentity.compactMap(URL.init(string:))
    }

    private var playbackAllowed: Bool {
        applicationActive
            && overlayController.activeStoryOverlay == nil
            && slotVisible
    }

    private func updateEligibility(
        _ geometry: StoryRailGeometry,
        viewport: CGRect? = nil,
        restartPlayback: Bool = false
    ) {
        let visibility = storyRailVisibility(
            rail: geometry.rail,
            cards: geometry.cards,
            viewport: viewport ?? viewportBounds
        )
        slotVisible = visibility.slotVisible
        let next = updateThumbnailPlaybackEligibility(
            current: restartPlayback ? [] : eligibleIndices,
            slotVisible: visibility.slotVisible,
            visibleFractions: visibility.cardFractions,
            items: config.items
        )
        eligibleIndices = next
        let playable = playableIndices(from: next)
        if restartPlayback {
            playbackRestartGeneration &+= 1
            sequentialActiveIndex = config.thumbnailVideoPlayback == .sequential
                ? nextThumbnailPlaybackIndex(eligible: playable, afterIndex: nil)
                : nil
        } else {
            reconcileSequentialActive(playable: playable)
        }
    }

    private func scheduleEligibilityAfterScroll(_ geometry: StoryRailGeometry) {
        // Pause while geometry is moving. Once it is stable, restart from the
        // first eligible campaign index rather than resuming the previous player.
        slotVisible = false
        scrollSettleTask?.cancel()
        scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            updateEligibility(geometry, restartPlayback: true)
        }
    }

    private func playableIndices(from eligible: Set<Int>) -> Set<Int> {
        Set(eligible.filter { index in
            guard config.items.indices.contains(index) else { return false }
            return failedPlayerIdentities[index] != thumbnailPlayerIdentity(config.items[index])
        })
    }

    private func restartEligiblePlayback() {
        applicationActive = true
        playbackRestartGeneration &+= 1
        guard config.thumbnailVideoPlayback == .sequential else { return }
        sequentialActiveIndex = nextThumbnailPlaybackIndex(
            eligible: playableIndices,
            afterIndex: nil
        )
    }

    private func reconcileSequentialActive(playable: Set<Int>) {
        guard config.thumbnailVideoPlayback == .sequential else {
            sequentialActiveIndex = nil
            return
        }
        if let current = sequentialActiveIndex, playable.contains(current) {
            return
        }
        sequentialActiveIndex = nextThumbnailPlaybackIndex(
            eligible: playable,
            afterIndex: sequentialActiveIndex
        )
    }

    private func advanceSequential(from index: Int) {
        guard config.thumbnailVideoPlayback == .sequential,
              sequentialActiveIndex == index
        else {
            return
        }
        sequentialActiveIndex = nextThumbnailPlaybackIndex(
            eligible: playableIndices,
            afterIndex: index
        )
    }

    private func markFailed(_ index: Int, playerIdentity: StoryThumbnailPlayerIdentity) {
        failedPlayerIdentities[index] = playerIdentity
        reconcileSequentialActive(playable: playableIndices)
    }
}

private struct StoryViewportReader: UIViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeUIView(context _: Context) -> StoryViewportUIView {
        let view = StoryViewportUIView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: StoryViewportUIView, context _: Context) {
        view.onChange = onChange
        view.reportViewportIfNeeded()
    }
}

private final class StoryViewportUIView: UIView {
    var onChange: ((CGRect) -> Void)?
    private var lastViewport = CGRect.null

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportViewportIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportViewportIfNeeded()
    }

    func reportViewportIfNeeded() {
        let next = window?.bounds ?? .null
        guard next != lastViewport else { return }
        lastViewport = next
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(next)
        }
    }
}

@MainActor
private struct StoryThumbnailCard: View {
    let item: StoryItemConfig
    let config: InlineStoryConfig
    let failed: Bool
    let playbackState: ThumbnailPlaybackViewState
    let onWindowCompleted: () -> Void
    let onFailed: () -> Void

    private var width: CGFloat {
        CGFloat(config.card.width)
    }

    var body: some View {
        ZStack {
            // Contained media leaves letterbox space. Keep that surface
            // opaque black across iOS, Android, and Flutter.
            Color.black
            if item.type == .video,
               !failed,
               shouldComposeThumbnailPlayer(
                   hasExplicitThumbnail: item.thumbnail != nil,
                   scheduled: playbackState.scheduled
               )
            {
                StoryThumbnailVideoView(
                    item: item,
                    state: playbackState,
                    onWindowCompleted: onWindowCompleted,
                    onFailed: onFailed
                )
                .id(thumbnailPlayerIdentity(item))
            } else if item.type == .video {
                StoryThumbnailPlaceholderView(thumbnail: item.thumbnail)
            } else {
                StoryRemoteImage(urlString: item.url, fit: item.thumbnailBoxFit)
            }
        }
        .frame(width: width, height: CGFloat(config.card.height))
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(config.card.borderRadius), style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - Dedicated story presenter

/// Presents the full-screen inline story as a modal `.overFullScreen`
/// `UIHostingController` on the app's top-most view controller.
///
/// We deliberately do NOT spin up a separate `UIWindow` here. A raw secondary
/// window works in a UIKit / React-Native host, but in a SwiftUI
/// `App`/`WindowGroup` host it renders its first frame and then stays inert:
/// SwiftUI never drives its update loop (frozen progress bar) and it never
/// joins the active responder chain (dead tap zones, swipe-dismiss and CTA).
/// A modal presentation is live and interactive in BOTH lifecycles. Being a
/// UIKit modal layered above any React-Native Fabric surface, it still owns
/// its touches outright — without competing with Fabric's
/// `RCTSurfaceTouchHandler` — mirroring the isolation Android gets from
/// presenting the story as a `Dialog`.
@MainActor
final class DigiaStoryPresenter {
    static let shared = DigiaStoryPresenter()

    /// The currently-presented story controller. Weak because UIKit retains a
    /// presented controller for us; we only need it to drive dismissal.
    private weak var presented: UIViewController?

    private init() {}

    func present(state: InlineStoryOverlayState) {
        // Replace any story already showing (e.g. tapping another story).
        // Tear the old one down without animation so it doesn't collide with
        // the incoming present.
        if let presented {
            self.presented = nil
            presented.presentingViewController?.dismiss(animated: false)
        }

        guard let presenter = ViewControllerUtil.topViewController() else { return }

        let host = DigiaStoryHostingController(rootView: InlineStoryOverlayContent(state: state))
        // Opaque black so the full-bleed media has no seam during the fade.
        host.view.backgroundColor = .black
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        presented = host
        presenter.present(host, animated: true)
    }

    func dismiss() {
        guard let presented else { return }
        self.presented = nil
        presented.presentingViewController?.dismiss(animated: true)
    }
}

private final class DigiaStoryHostingController<Content: View>: UIHostingController<Content> {
    // The interactive "back" (left-edge swipe) and swipe-down dismissals are
    // handled inside the SwiftUI DragGesture in InlineStoryOverlayContent, not
    // by a UIKit gesture recognizer here — a separate UIScreenEdgePanGesture on
    // this view would be starved by SwiftUI's own pan recognizer. This
    // controller only adds hardware-keyboard ESC dismissal (e.g. simulator).
    override var canBecomeFirstResponder: Bool {
        true
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                action: #selector(dismissStoryOverlay)
            )
        ]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    @objc private func dismissStoryOverlay() {
        SDKInstance.shared.controller.dismissStoryOverlay()
    }
}

/// The two-param `onChange(of:initial:_:)` needs iOS 17; below that, `.onAppear`
/// plus the older single-value `onChange` reports the same "fire now and on every
/// subsequent change" sequence.
private struct StoryStepViewedReporter: ViewModifier {
    let currentIndex: Int
    let report: (Int) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.onChange(of: currentIndex, initial: true) { _, idx in report(idx) }
        } else {
            content
                .onAppear { report(currentIndex) }
                .onChange(of: currentIndex) { idx in report(idx) }
        }
    }
}

@MainActor
private struct InlineStoryOverlayContent: View {
    let state: InlineStoryOverlayState

    @State private var currentIndex: Int
    @State private var displayedIndex: Int
    @State private var elapsed: Double = 0
    @State private var videoProgress: Double = 0
    @State private var videoStalled: Double = 0
    @State private var lastVideoProgress: Double = 0
    /// True while the current video is buffering (waiting to play). The stall
    /// watchdog pauses while this is set so a slow network isn't mistaken for a
    /// dead video and skipped.
    @State private var videoBuffering = false
    /// Set when the story runs to its last frame, so the teardown reports
    /// `Completed` rather than `StepDismissed`.
    @State private var completed = false
    @State private var openedAt = Date()
    /// Nil until the viewer changes the audio state. Before that, the story's
    /// authored `startMuted` applies; afterwards the viewer's choice persists.
    @State private var muteOverride: Bool?

    init(state: InlineStoryOverlayState) {
        self.state = state
        let initialIndex = min(max(state.initialIndex, 0), max(state.config.items.count - 1, 0))
        _currentIndex = State(initialValue: initialIndex)
        _displayedIndex = State(initialValue: initialIndex)
    }

    private var variables: VariableContext {
        buildVariableContext(schemas: state.config.variableSchemas, cepVars: state.payload.variables)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                if let item = currentItem {
                    let muted = muteOverride ?? state.config.startMuted
                    ForEach(renderedIndices, id: \.self) { index in
                        if state.config.items.indices.contains(index) {
                            FullScreenStoryItem(
                                item: state.config.items[index],
                                active: index == currentIndex,
                                muted: muted,
                                onVideoReady: {
                                    guard index == currentIndex else { return }
                                    displayedIndex = index
                                },
                                onVideoProgress: {
                                    guard index == currentIndex else { return }
                                    videoProgress = $0
                                },
                                onVideoEnded: {
                                    guard index == currentIndex else { return }
                                    next()
                                },
                                onVideoBuffering: {
                                    guard index == currentIndex else { return }
                                    videoBuffering = $0
                                }
                            )
                            .id(index)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .opacity(index == displayedIndex ? 1 : 0)
                        }
                    }

                    tapZones

                    VStack(spacing: 0) {
                        StoryProgressIndicator(
                            totalItems: state.config.items.count,
                            currentIndex: currentIndex,
                            progress: progress,
                            config: state.config.indicator
                        )
                        // `proxy.safeAreaInsets` is zero here because the
                        // GeometryReader ignores the safe area for full-bleed
                        // media, so we source the real device insets from the
                        // window instead (see `safeAreaInsets`).
                        .padding(.top, CGFloat(state.config.indicator.topPadding) + safeAreaInsets.top)
                        .padding(.horizontal, CGFloat(state.config.indicator.horizontalPadding))

                        Spacer(minLength: 0)

                        if item.ctaEnabled, let text = item.ctaText, !text.isEmpty {
                            StoryCTAButton(item: item, variables: variables) {
                                handleCTA(item)
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, safeAreaInsets.bottom + 20)
                        }
                    }

                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)

                            if item.type == .video, state.config.muteButton.visible {
                                StoryOverlayButton(
                                    config: state.config.muteButton,
                                    systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                    accessibilityLabel: muted ? "Unmute story" : "Mute story",
                                    action: { muteOverride = !muted }
                                )
                            }

                            if state.config.closeButton.visible {
                                StoryOverlayButton(
                                    config: state.config.closeButton,
                                    systemImage: "xmark",
                                    accessibilityLabel: "Close story",
                                    action: { SDKInstance.shared.controller.dismissStoryOverlay() }
                                )
                            }
                        }
                        .padding(
                            .top,
                            safeAreaInsets.top
                                + CGFloat(state.config.indicator.topPadding)
                                + CGFloat(state.config.indicator.height)
                                + 12
                        )
                        .padding(.trailing, CGFloat(state.config.indicator.horizontalPadding))

                        Spacer(minLength: 0)
                    }
                }
            }
            .contentShape(Rectangle())
            // Dismissal gestures live in a single SwiftUI DragGesture so they
            // don't fight a separate UIKit recognizer (which SwiftUI's own pan
            // would starve). Two "back" affordances:
            //   • swipe DOWN  — standard full-screen-cover dismissal
            //   • swipe RIGHT from the left edge — iOS interactive "back"
            // `simultaneousGesture` (not `gesture`) so this doesn't claim exclusive
            // recognition over the left/right `tapZones` beneath it — a plain
            // `.gesture()` here was swallowing taps meant for story navigation.
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        let dy = value.translation.height
                        let dx = value.translation.width
                        let predictedDX = value.predictedEndTranslation.width
                        let swipeDown = dy > 48 && dy > abs(dx)
                        let edgeBack =
                            value.startLocation.x < 40
                            && dx > abs(dy)
                            && (dx > 80 || predictedDX > 200)
                        if swipeDown || edgeBack {
                            SDKInstance.shared.controller.dismissStoryOverlay()
                        }
                    }
            )
        }
        .ignoresSafeArea()
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            tick()
        }
        // Step Viewed fires for each frame that becomes visible (including the
        // first), mirroring Android's LaunchedEffect(currentStoryIndex).
        //
        // The two-param `onChange(of:initial:_:)` needs iOS 17; below that,
        // `.onAppear` plus the older single-value `onChange` reports the same
        // "fire now and on every subsequent change" sequence.
        .modifier(StoryStepViewedReporter(currentIndex: currentIndex) { idx in
            SDKInstance.shared.reportStoryStepViewed(
                state.payload,
                itemIndex: idx + 1,
                itemTotal: state.config.items.count
            )
        })
        // Any teardown before the last frame is a user dismissal (swipe / edge /
        // ESC). Completion sets `completed` first, so it reports only once there.
        .onDisappear {
            if !completed {
                SDKInstance.shared.reportStoryStepDismissed(state.payload, itemIndex: currentIndex + 1)
            }
        }
    }

    /// Real device safe-area insets, read from the active window. The
    /// enclosing GeometryReader uses `.ignoresSafeArea()` for full-bleed media,
    /// which makes its own `safeAreaInsets` report zero — so the progress bar
    /// (and CTA) would otherwise sit under the notch / home indicator.
    private var safeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .map(\.safeAreaInsets)
            .first(where: { $0.top > 0 }) ?? .zero
    }

    private var currentItem: StoryItemConfig? {
        state.config.items.indices.contains(currentIndex) ? state.config.items[currentIndex] : nil
    }

    private var renderedIndices: [Int] {
        displayedIndex == currentIndex
            ? [currentIndex]
            : [displayedIndex, currentIndex]
    }

    private var currentDuration: Double {
        let ms = currentItem?.duration ?? state.config.defaultDuration
        return max(Double(ms) / 1000.0, 0.1)
    }

    private var progress: Double {
        if currentItem?.type == .video {
            return min(max(videoProgress, 0), 1)
        }
        return min(max(elapsed / currentDuration, 0), 1)
    }

    private var tapZones: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: 88)
                .onTapGesture { previous() }

            Spacer(minLength: 0)

            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: 88)
                .onTapGesture { next() }
        }
    }

    private func tick() {
        guard let item = currentItem else { return }
        if item.type == .video {
            // Buffering is legitimate loading, not a stall — pause the watchdog
            // so a slow network doesn't skip the video before it starts.
            if videoBuffering { return }
            if videoProgress > lastVideoProgress + 0.0001 {
                lastVideoProgress = videoProgress
                videoStalled = 0
            } else {
                videoStalled += 0.05
                if videoStalled >= 10 { next() }
            }
            return
        }
        elapsed += 0.05
        if elapsed >= currentDuration {
            next()
        }
    }

    private func resetTiming() {
        elapsed = 0
        videoProgress = 0
        lastVideoProgress = 0
        videoStalled = 0
        videoBuffering = false
    }

    private func next() {
        resetTiming()
        if currentIndex < state.config.items.count - 1 {
            move(to: currentIndex + 1)
        } else if state.config.restartOnCompleted {
            move(to: 0)
        } else {
            completed = true
            SDKInstance.shared.reportStoryCompleted(
                state.payload,
                itemTotal: state.config.items.count,
                timeToCompleteMs: Int64(Date().timeIntervalSince(openedAt) * 1000)
            )
            SDKInstance.shared.controller.dismissStoryOverlay()
        }
    }

    private func previous() {
        resetTiming()
        move(to: max(currentIndex - 1, 0))
    }

    private func move(to index: Int) {
        currentIndex = index
        if state.config.items[index].type != .video {
            displayedIndex = index
        }
    }

    private func handleCTA(_ item: StoryItemConfig) {
        let actions = item.actions
        let reportedAction = actions.first?.resolved(with: variables)
        let label = item.ctaText.map { interpolate($0, context: variables) }
        SDKInstance.shared.reportStoryStepClicked(
            state.payload,
            itemIndex: currentIndex + 1,
            ctaLabel: label,
            actionType: reportedAction?.analyticsType,
            actionUrl: reportedAction?.analyticsURL
        )
        Task {
            await SDKInstance.shared.executeActionFlow(
                actions,
                variables: variables,
                localActionExecutor: LocalActionExecutor(
                    dismiss: { SDKInstance.shared.controller.dismissStoryOverlay() }
                )
            )
        }
    }
}

@MainActor
private struct FullScreenStoryItem: View {
    let item: StoryItemConfig
    let active: Bool
    let muted: Bool
    let onVideoReady: @MainActor @Sendable () -> Void
    let onVideoProgress: @MainActor @Sendable (Double) -> Void
    let onVideoEnded: @MainActor @Sendable () -> Void
    let onVideoBuffering: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black
            if item.type == .video {
                StoryThumbnailPlaceholderView(
                    thumbnail: item.thumbnail,
                    fitOverride: item.boxFit
                )
                if item.thumbnail == nil,
                   let poster = StoryThumbnailPosterCache.image(
                       for: thumbnailPlayerIdentity(item)
                   ) {
                    StoryPosterImage(image: poster, fit: item.boxFit)
                }
                InlineStoryVideoView(
                    urlString: item.url,
                    looping: false,
                    active: active,
                    muted: muted,
                    gravity: item.boxFit.videoGravity,
                    onReadyForDisplay: onVideoReady,
                    onProgress: onVideoProgress,
                    onEnded: onVideoEnded,
                    onBuffering: onVideoBuffering
                )
            } else {
                StoryRemoteImage(urlString: item.url, fit: item.boxFit)
            }
        }
    }
}

private struct StoryPosterImage: View {
    let image: UIImage
    let fit: StoryMediaFit

    @ViewBuilder
    var body: some View {
        let content = Image(uiImage: image).resizable()
        if fit.stretchesImage {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.aspectRatio(contentMode: fit.imageContentMode)
        }
    }
}

@MainActor
private struct StoryRemoteImage: View {
    let urlString: String
    let fit: StoryMediaFit

    @ViewBuilder
    var body: some View {
        if let url = URL(string: urlString) {
            let image = DigiaCachedImageView(
                url: url,
                placeholder: AnyView(Color(red: 0.10, green: 0.10, blue: 0.10))
            )
            if fit.stretchesImage {
                image.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                image.aspectRatio(contentMode: fit.imageContentMode)
            }
        } else {
            Color(red: 0.16, green: 0.16, blue: 0.16)
        }
    }
}

@MainActor
private struct InlineStoryVideoView: View {
    let urlString: String
    let looping: Bool
    var active: Bool = true
    let muted: Bool
    /// Configurable cover/contain scaling shared by thumbnails and full-screen playback.
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var onReadyForDisplay: (@MainActor @Sendable () -> Void)?
    /// Full-screen playback hooks; thumbnails leave these nil and skip the
    /// observers entirely.
    var onProgress: (@MainActor @Sendable (Double) -> Void)?
    var onEnded: (@MainActor @Sendable () -> Void)?
    var onBuffering: (@MainActor @Sendable (Bool) -> Void)?

    @State private var bundle: DigiaVideoPlaybackBundle?
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var failObserver: NSObjectProtocol?
    @State private var bufferingObserver: NSKeyValueObservation?
    @State private var itemStatusObserver: NSKeyValueObservation?
    @State private var firstFrameReady = false
    @State private var endReported = false

    var body: some View {
        ZStack {
            if let player = bundle?.player {
                InlineStoryPlayerLayer(
                    player: player,
                    gravity: gravity,
                    onReadyForDisplay: {
                        guard !firstFrameReady else { return }
                        firstFrameReady = true
                        onBuffering?(false)
                        onReadyForDisplay?()
                    }
                )
                .opacity(firstFrameReady ? 1 : 0)
            }
        }
        .task(id: "\(urlString)-\(looping)") {
            tearDownPlayback()
            firstFrameReady = false
            endReported = false
            guard let url = URL(string: urlString) else {
                reportEnd()
                return
            }

            guard let nextBundle = try? await DigiaVideoPlaybackBundle.make(
                url: url,
                looping: looping
            ) else {
                reportEnd()
                return
            }
            guard !Task.isCancelled else {
                nextBundle.releasePlaybackResources()
                return
            }
            nextBundle.player.isMuted = muted

            if let onProgress {
                let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
                timeObserver = nextBundle.player.addPeriodicTimeObserver(
                    forInterval: interval,
                    queue: .main
                ) { [weak player = nextBundle.player] time in
                    Task { @MainActor in
                        guard let item = player?.currentItem, firstFrameReady else { return }
                        let duration = item.duration.seconds
                        guard duration.isFinite, duration > 0 else { return }
                        onProgress(min(max(time.seconds / duration, 0), 1))
                    }
                }
            }
            if onEnded != nil {
                // Advance on natural completion or on an unplayable item, so a
                // broken URL doesn't leave the story stuck on a black frame.
                itemStatusObserver = nextBundle.player.currentItem?.observe(
                    \.status,
                    options: [.initial, .new]
                ) { item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in reportEnd() }
                }
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: nextBundle.player.currentItem,
                    queue: .main
                ) { _ in
                    Task { @MainActor in reportEnd() }
                }
                failObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: nextBundle.player.currentItem,
                    queue: .main
                ) { _ in
                    Task { @MainActor in reportEnd() }
                }
            }
            if let onBuffering {
                // Report waiting-to-play so the story's stall watchdog can tell
                // a buffering video from a dead one.
                bufferingObserver = nextBundle.player.observe(
                    \.timeControlStatus,
                    options: [.initial, .new]
                ) { player, _ in
                    let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    Task { @MainActor in onBuffering(waiting) }
                }
            }

            bundle = nextBundle
            if active {
                nextBundle.player.play()
            }
        }
        .onChange(of: active) { shouldPlay in
            if shouldPlay {
                bundle?.player.play()
            } else {
                bundle?.player.pause()
            }
        }
        .onChange(of: muted) { isMuted in
            bundle?.player.isMuted = isMuted
        }
        .onDisappear {
            tearDownPlayback()
        }
    }

    private func reportEnd() {
        guard !endReported else { return }
        endReported = true
        // Hide a possible black encoded end frame and expose the cached poster
        // while the next story prepares its correctly fitted first frame.
        firstFrameReady = false
        onEnded?()
    }

    private func tearDownPlayback() {
        guard let bundle else { return }

        if let timeObserver {
            bundle.player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
        }
        bufferingObserver?.invalidate()
        itemStatusObserver?.invalidate()

        bundle.releasePlaybackResources()

        timeObserver = nil
        endObserver = nil
        failObserver = nil
        bufferingObserver = nil
        itemStatusObserver = nil
        firstFrameReady = false
        self.bundle = nil
    }
}

extension StoryMediaFit {
    var stretchesImage: Bool { self == .fill }

    var imageContentMode: ContentMode { self == .contain ? .fit : .fill }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .cover: .resizeAspectFill
        case .contain: .resizeAspect
        case .fill: .resize
        }
    }
}

private struct StoryOverlayButton: View {
    let config: StoryOverlayButtonConfig
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: CGFloat(config.size) * 0.5, weight: .regular))
                .foregroundStyle(Color(hex: config.iconColor) ?? .white)
                .frame(width: CGFloat(config.size), height: CGFloat(config.size))
                .background(Color(hex: config.backgroundColor) ?? .black)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(
            width: max(CGFloat(config.size), 48),
            height: max(CGFloat(config.size), 48)
        )
        .accessibilityLabel(accessibilityLabel)
    }
}

struct InlineStoryPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var onReadyForDisplay: (() -> Void)?

    func makeUIView(context _: Context) -> InlineStoryPlayerContainer {
        let view = InlineStoryPlayerContainer()
        view.configure(
            player: player,
            gravity: gravity,
            onReadyForDisplay: onReadyForDisplay
        )
        return view
    }

    func updateUIView(_ uiView: InlineStoryPlayerContainer, context _: Context) {
        uiView.configure(
            player: player,
            gravity: gravity,
            onReadyForDisplay: onReadyForDisplay
        )
    }

    static func dismantleUIView(_ uiView: InlineStoryPlayerContainer, coordinator _: Void) {
        uiView.tearDown()
    }
}

final class InlineStoryPlayerContainer: UIView {
    private var readyObservation: NSKeyValueObservation?
    private var observedPlayer: AVPlayer?
    private var didReportReady = false
    private var onReadyForDisplay: (() -> Void)?

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    func configure(
        player: AVPlayer,
        gravity: AVLayerVideoGravity,
        onReadyForDisplay: (() -> Void)?
    ) {
        self.onReadyForDisplay = onReadyForDisplay
        playerLayer.videoGravity = gravity
        guard observedPlayer !== player else {
            revealIfReady()
            return
        }
        readyObservation?.invalidate()
        observedPlayer = player
        didReportReady = false
        playerLayer.opacity = 0
        playerLayer.player = player
        readyObservation = playerLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.revealIfReady() }
        }
    }

    func tearDown() {
        readyObservation?.invalidate()
        readyObservation = nil
        observedPlayer = nil
        onReadyForDisplay = nil
        didReportReady = false
        playerLayer.opacity = 0
        playerLayer.player = nil
    }

    private func revealIfReady() {
        guard playerLayer.isReadyForDisplay else { return }
        playerLayer.opacity = 1
        guard !didReportReady else { return }
        didReportReady = true
        onReadyForDisplay?()
    }
}

private struct StoryProgressIndicator: View {
    let totalItems: Int
    let currentIndex: Int
    let progress: Double
    let config: StoryIndicatorDisplayConfig

    var body: some View {
        HStack(spacing: CGFloat(config.horizontalGap)) {
            ForEach(0..<max(totalItems, 0), id: \.self) { index in
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: CGFloat(config.borderRadius), style: .continuous)
                            .fill(backgroundColor(for: index))
                        RoundedRectangle(cornerRadius: CGFloat(config.borderRadius), style: .continuous)
                            .fill(Color(hex: config.activeColor) ?? .white)
                            .frame(width: proxy.size.width * CGFloat(fillAmount(for: index)))
                    }
                }
                .frame(height: CGFloat(config.height))
            }
        }
    }

    private func fillAmount(for index: Int) -> Double {
        if index < currentIndex { return 0 }
        if index == currentIndex { return min(max(progress, 0), 1) }
        return 0
    }

    private func backgroundColor(for index: Int) -> Color {
        if index < currentIndex {
            return Color(hex: config.activeColor) ?? Color.white.opacity(0.67)
        }
        return Color(hex: config.disabledColor) ?? Color.white.opacity(0.34)
    }
}

private struct StoryCTAButton: View {
    let item: StoryItemConfig
    let variables: VariableContext
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(interpolate(item.ctaText ?? "", context: variables))
                .font(
                    Font(SDKInstance.shared.font.resolve(
                        size: 16,
                        weight: item.ctaFontWeight,
                        italic: false
                    ))
                )
                .foregroundColor(Color(hex: item.ctaTextColor) ?? .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .background(Color(hex: item.ctaBackgroundColor) ?? Color(hex: "#4945FF") ?? .blue)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(item.ctaCornerRadius), style: .continuous))
    }
}
