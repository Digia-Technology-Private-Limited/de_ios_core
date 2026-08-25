import AVFoundation
import SwiftUI
import UIKit

private let storyRailCoordinateSpace = "DigiaInlineStoryRail"

@MainActor
final class InlineStoryRailPlaybackStore: ObservableObject {
    @Published private(set) var coordinator: InlineStoryRailPlaybackCoordinator

    init(items: [StoryItemConfig], mode: ThumbnailVideoPlaybackMode) {
        coordinator = InlineStoryRailPlaybackCoordinator(items: items, mode: mode)
    }

    func send(_ event: InlineStoryRailPlaybackEvent) {
        var next = coordinator
        next.send(event)
        coordinator = next
    }
}

@MainActor
struct DigiaInlineStoryView: View {
    let config: InlineStoryConfig
    let payload: CEPTriggerPayload

    @ObservedObject private var overlayController = SDKInstance.shared.controller

    init(config: InlineStoryConfig, payload: CEPTriggerPayload) {
        self.config = config
        self.payload = payload
    }

    var body: some View {
        StoryThumbnailRailView(
            items: config.items,
            mode: config.thumbnailVideoPlayback,
            cardWidth: CGFloat(config.card.width),
            cardHeight: CGFloat(config.card.height),
            cardCornerRadius: CGFloat(config.card.borderRadius),
            cardSpacing: CGFloat(config.card.spacing),
            overlayOpen: overlayController.activeStoryOverlay != nil
        ) { index in
            SDKInstance.shared.reportStoryOpened(payload)
            SDKInstance.shared.controller.showStoryOverlay(
                config: config,
                initialIndex: index,
                payload: payload
            )
        }
    }
}

@MainActor
struct StoryThumbnailRailView: View {
    let items: [StoryItemConfig]
    let mode: ThumbnailVideoPlaybackMode
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let cardCornerRadius: CGFloat
    let cardSpacing: CGFloat
    let overlayOpen: Bool
    let onOpen: @MainActor (Int) -> Void

    @StateObject private var playbackStore: InlineStoryRailPlaybackStore
    @State private var latestGeometry = StoryRailGeometry()
    @State private var viewportBounds = CGRect.null
    @State private var scrollSettleTask: Task<Void, Never>?
    @State private var lastSettledVisibility: StoryRailVisibility?
    @State private var cacheDemandOwner = UUID()

    init(
        items: [StoryItemConfig],
        mode: ThumbnailVideoPlaybackMode,
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        cardCornerRadius: CGFloat,
        cardSpacing: CGFloat,
        overlayOpen: Bool,
        onOpen: @escaping @MainActor (Int) -> Void
    ) {
        self.items = items
        self.mode = mode
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.cardCornerRadius = cardCornerRadius
        self.cardSpacing = cardSpacing
        self.overlayOpen = overlayOpen
        self.onOpen = onOpen
        _playbackStore = StateObject(wrappedValue: InlineStoryRailPlaybackStore(
            items: items,
            mode: mode
        ))
    }

    private var playback: InlineStoryRailPlaybackCoordinator {
        playbackStore.coordinator
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let playerIdentity = thumbnailPlayerIdentity(item)
                    StoryThumbnailCard(
                        index: index,
                        item: item,
                        width: cardWidth,
                        height: cardHeight,
                        cornerRadius: cardCornerRadius,
                        playbackStore: playbackStore,
                        onWindowCompleted: { playbackStore.send(.windowCompleted(index)) },
                        onFailed: {
                            playbackStore.send(.failed(index: index, identity: playerIdentity))
                        }
                    )
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: StoryRailGeometryPreference.self,
                                    value: StoryRailGeometry(cards: [
                                        index: proxy.frame(in: .named(storyRailCoordinateSpace))
                                    ])
                                )
                            }
                        }
                        .onTapGesture {
                            onOpen(index)
                        }
                }
            }
            .padding(.horizontal, cardSpacing)
        }
        .coordinateSpace(name: storyRailCoordinateSpace)
        .background {
            ZStack {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: StoryRailGeometryPreference.self,
                        value: StoryRailGeometry(
                            rail: CGRect(origin: .zero, size: proxy.size)
                        )
                    )
                }
                StoryViewportReader { viewport in
                    guard viewportBounds != viewport else { return }
                    viewportBounds = viewport
                    scheduleEligibilityAfterScroll(latestGeometry)
                }
            }
        }
        .onPreferenceChange(StoryRailGeometryPreference.self) { geometry in
            latestGeometry = geometry
            scheduleEligibilityAfterScroll(geometry)
        }
        .onAppear {
            playbackStore.send(.configuration(
                items: items,
                mode: mode
            ))
            playbackStore.send(.overlayChanged(overlayOpen))
            playbackStore.send(.applicationActive(
                UIApplication.shared.applicationState == .active
            ))
            Task { @MainActor in
                await Task.yield()
                settleVisibility(latestGeometry)
            }
        }
        .onDisappear {
            scrollSettleTask?.cancel()
            scrollSettleTask = nil
            let owner = cacheDemandOwner
            Task { await DigiaVideoFileCache.shared.clearDemand(owner: owner) }
        }
        .task(id: playback.videoDemands) {
            await DigiaVideoFileCache.shared.prepare(
                playback.videoDemands,
                owner: cacheDemandOwner
            )
        }
        .onChange(of: StoryRailConfigurationIdentity(items: items, mode: mode)) { _ in
            playbackStore.send(.configuration(
                items: items,
                mode: mode
            ))
            lastSettledVisibility = nil
            scheduleEligibilityAfterScroll(latestGeometry)
        }
        .onChange(of: overlayOpen) { open in
            playbackStore.send(.overlayChanged(open))
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            playbackStore.send(.applicationActive(true))
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification
        )) { _ in
            playbackStore.send(.applicationActive(false))
        }
        .frame(height: cardHeight)
    }

    private func settleVisibility(_ geometry: StoryRailGeometry) {
        guard let rail = geometry.rail,
              !rail.isNull,
              !rail.isEmpty,
              !geometry.cards.isEmpty,
              !viewportBounds.isNull,
              !viewportBounds.isEmpty else { return }
        let visibility = storyRailVisibility(
            rail: rail,
            cards: geometry.cards,
            viewport: viewportBounds
        )
        guard visibility.isMateriallyDifferent(
            from: lastSettledVisibility,
            retaining: playback.state.eligibleIndices
        ) else { return }
        lastSettledVisibility = visibility
        playbackStore.send(.scrollSettled(visibility))
    }

    private func scheduleEligibilityAfterScroll(_ geometry: StoryRailGeometry) {
        scrollSettleTask?.cancel()
        scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            settleVisibility(geometry)
        }
    }

}

private extension StoryRailVisibility {
    func isMateriallyDifferent(
        from previous: StoryRailVisibility?,
        retaining eligibleIndices: Set<Int>
    ) -> Bool {
        guard let previous else { return true }
        guard slotVisible == previous.slotVisible else { return true }
        let indices = Set(cardFractions.keys).union(previous.cardFractions.keys)
        let changed = indices.filter { index in
            abs((cardFractions[index] ?? 0) - (previous.cardFractions[index] ?? 0)) > 0.01
        }
        guard !changed.isEmpty else { return false }
        // A passive SwiftUI preference pass may briefly omit an eligible card.
        // Ignore that pass unless another measured card actually moved.
        return !changed.allSatisfy { index in
            eligibleIndices.contains(index) && cardFractions[index] == nil
        }
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
    private var scrollObservations: [NSKeyValueObservation] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        observeAncestorScrollViews()
        reportViewportIfNeeded()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        observeAncestorScrollViews()
        reportViewportIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportViewportIfNeeded()
    }

    func reportViewportIfNeeded() {
        guard let window else {
            report(.null)
            return
        }

        var visibleInWindow = convert(bounds, to: window).intersection(window.bounds)
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds {
                visibleInWindow = visibleInWindow.intersection(
                    view.convert(view.bounds, to: window)
                )
            }
            ancestor = view.superview
        }
        let next = visibleInWindow.isNull || visibleInWindow.isEmpty
            ? CGRect.null
            : convert(visibleInWindow, from: window)
        report(next)
    }

    private func observeAncestorScrollViews() {
        scrollObservations.removeAll()
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                scrollObservations.append(
                    scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor in self?.reportViewportIfNeeded() }
                    }
                )
            }
            ancestor = view.superview
        }
    }

    private func report(_ next: CGRect) {
        guard !viewport(next, isApproximatelyEqualTo: lastViewport) else { return }
        lastViewport = next
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(next)
        }
    }

    private func viewport(
        _ lhs: CGRect,
        isApproximatelyEqualTo rhs: CGRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        if lhs.isNull || rhs.isNull {
            return lhs.isNull && rhs.isNull
        }
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

@MainActor
private struct StoryThumbnailCard: View {
    let index: Int
    let item: StoryItemConfig
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    @ObservedObject var playbackStore: InlineStoryRailPlaybackStore
    let onWindowCompleted: @MainActor @Sendable () -> Void
    let onFailed: @MainActor @Sendable () -> Void

    private var playbackState: ThumbnailPlaybackViewState {
        playbackStore.coordinator.playbackState(for: index)
    }

    private var failed: Bool {
        playbackStore.coordinator.state.failedPlayerIdentities[index]
            == thumbnailPlayerIdentity(item)
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
                    index: index,
                    item: item,
                    playbackStore: playbackStore,
                    onWindowCompleted: onWindowCompleted,
                    onFailed: onFailed
                )
                .id(StoryThumbnailViewIdentity(
                    index: index,
                    player: thumbnailPlayerIdentity(item)
                ))
            } else if item.type == .video {
                StoryThumbnailPlaceholderView(thumbnail: item.thumbnail)
            } else {
                StoryRemoteImage(urlString: item.url, fit: item.thumbnailBoxFit)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct StoryThumbnailViewIdentity: Hashable {
    let index: Int
    let player: StoryThumbnailPlayerIdentity
}

private struct StoryRailConfigurationIdentity: Equatable {
    let players: [StoryThumbnailPlayerIdentity]
    let mode: ThumbnailVideoPlaybackMode

    init(items: [StoryItemConfig], mode: ThumbnailVideoPlaybackMode) {
        players = items.map(thumbnailPlayerIdentity)
        self.mode = mode
    }

    init(config: InlineStoryConfig) {
        self.init(items: config.items, mode: config.thumbnailVideoPlayback)
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
    @State private var videoReady = false
    /// True while the current video is buffering (waiting to play). The stall
    /// watchdog pauses while this is set so a slow network isn't mistaken for a
    /// dead video and skipped.
    @State private var videoBuffering = false
    @State private var applicationActive = UIApplication.shared.applicationState == .active
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
                                    videoReady = true
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
        guard applicationActive, let item = currentItem else { return }
        if item.type == .video {
            // File download and buffering are legitimate loading. Start the
            // watchdog only after AVPlayer has displayed its first frame.
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
        videoReady = false
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
                InlineStoryVideoView(
                    item: item,
                    active: active,
                    muted: muted,
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

/// A story's still media, sized the way a story sizes it.
///
/// Not private: the canvas story draws the same stills, on its rail cards and
/// behind its full-screen pages. Its own version used a bare
/// `.aspectRatio(contentMode: .fill)`, which reports an ideal size larger than
/// the box it was given — enough to grow the enclosing stack and push the
/// story's chrome off the top of the screen.
@MainActor
struct StoryRemoteImage: View {
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
    let item: StoryItemConfig
    var active: Bool = true
    let muted: Bool
    var onReadyForDisplay: (@MainActor @Sendable () -> Void)?
    var onProgress: (@MainActor @Sendable (Double) -> Void)?
    var onEnded: (@MainActor @Sendable () -> Void)?
    var onBuffering: (@MainActor @Sendable (Bool) -> Void)?

    @StateObject private var playback: StoryVideoPlayback

    init(
        item: StoryItemConfig,
        active: Bool = true,
        muted: Bool,
        onReadyForDisplay: (@MainActor @Sendable () -> Void)? = nil,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil,
        onEnded: (@MainActor @Sendable () -> Void)? = nil,
        onBuffering: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.item = item
        self.active = active
        self.muted = muted
        self.onReadyForDisplay = onReadyForDisplay
        self.onProgress = onProgress
        self.onEnded = onEnded
        self.onBuffering = onBuffering
        _playback = StateObject(wrappedValue: StoryVideoPlayback(
            urlString: item.url,
            purpose: .fullScreen(item)
        ))
    }

    var body: some View {
        ZStack {
            if item.thumbnail == nil, let poster = playback.poster {
                StoryPosterImage(image: poster, fit: item.boxFit)
            }
            if let player = playback.player {
                InlineStoryPlayerLayer(
                    player: player,
                    gravity: item.boxFit.videoGravity,
                    onReadyForDisplay: playback.playerLayerDidBecomeReady
                )
                .opacity(playback.showPlayerLayer ? 1 : 0)
            }
        }
        .onAppear(perform: updatePlayback)
        .onChange(of: active) { _ in updatePlayback() }
        .onChange(of: muted) { _ in updatePlayback() }
        .onDisappear { playback.tearDown() }
    }

    private func updatePlayback() {
        playback.update(
            state: StoryVideoPlaybackState(
                demand: .playback(.fullScreen),
                active: active,
                muted: muted,
                repeatWindow: false,
                restartGeneration: 0
            ),
            events: StoryVideoPlaybackEvents(
                onReady: { onReadyForDisplay?() },
                onProgress: { onProgress?($0) },
                onEnded: { onEnded?() },
                onBuffering: { onBuffering?($0) },
                // A broken full-screen item advances rather than trapping the viewer.
                onFailed: { onEnded?() }
            )
        )
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

    // A raw video rendering surface, never itself interactive in either consumer
    // (inline story or floater/PIP) — both render separate SwiftUI content above it
    // for actual interaction. Set explicitly rather than relying on the SwiftUI
    // `.allowsHitTesting(false)` modifier callers apply: that modifier's propagation
    // across a `UIViewRepresentable` boundary proved unreliable elsewhere in this
    // hosting stack (see `floater_overlay_view.swift`'s `FloaterSessionView` — the
    // floater's own drag/tap gesture and its chrome buttons stopped receiving touches
    // wherever this view's real, UIKit-default-`true` `isUserInteractionEnabled` won
    // hit-testing priority over them instead).
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
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
