import AVFoundation
import SwiftUI
import UIKit

private let storyRailCoordinateSpace = "DigiaInlineStoryRail"

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
        if let image = config.previewImage {
            SingleImageStoryPreview(image: image) { openStory(at: 0, handoffKey: nil) }
                .environment(\.digiaCampaignKey, payload.campaignKey)
        } else {
            rail
        }
    }

    private func openStory(at index: Int, handoffKey: String?) {
        SDKInstance.shared.reportStoryOpened(payload)
        SDKInstance.shared.reportClassicStoryOpened(payload, index: index)
        // The overlay state (not mine to change) carries no handoff: stash it on the presenter
        // the overlay reads at init, on the same MainActor turn — deterministic.
        DigiaStoryPresenter.shared.pendingHandoffKey = handoffKey
        SDKInstance.shared.controller.showStoryOverlay(
            config: config,
            initialIndex: index,
            payload: payload
        )
    }

    private var rail: some View {
        StoryThumbnailRailView(
            items: config.items,
            mode: config.thumbnailVideoPlayback,
            cardWidth: CGFloat(config.card.width),
            cardHeight: CGFloat(config.card.height),
            cardCornerRadius: CGFloat(config.card.borderRadius),
            cardSpacing: CGFloat(config.card.spacing),
            overlayOpen: overlayController.activeStoryOverlay != nil,
            onOpenWithHandoff: { openStory(at: $0, handoffKey: $1) },
            onOpen: { openStory(at: $0, handoffKey: nil) }
        )
        .environment(\.digiaCampaignKey, payload.campaignKey)
    }
}

@MainActor
private struct SingleImageStoryPreview: View {
    let image: StoryPreviewImageConfig
    let onTap: () -> Void

    var body: some View {
        let media = Color.black
            .overlay(StoryRemoteImage(urlString: image.url, fit: image.boxFit))
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(image.cornerRadius), style: .continuous))
        Group {
            if image.aspectRatio > 0 {
                media.aspectRatio(CGFloat(image.aspectRatio), contentMode: .fit)
            } else {
                media.frame(height: CGFloat(image.height))
            }
        }
        .padding(EdgeInsets(
            top: image.padding.top, leading: image.padding.left,
            bottom: image.padding.bottom, trailing: image.padding.right
        ))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// The inline rail: one `StoryRail` shared by inline, canvas and floater entry points (canvas
/// hosts this same view). Owns the 75%/25% visibility rule and take-turns through
/// `StoryRailState`; each card only obeys play/pause. A received `simultaneous` mode parses
/// (wire compat) but schedules as sequential (D7).
@MainActor
struct StoryThumbnailRailView: View {
    let items: [StoryItemConfig]
    /// Accepted for wire compat; scheduling always takes turns (D7).
    let mode: ThumbnailVideoPlaybackMode
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let cardCornerRadius: CGFloat
    let cardSpacing: CGFloat
    let overlayOpen: Bool
    let prefetch: any MediaPrefetch
    let onOpenWithHandoff: ((Int, String?) -> Void)?
    let onOpen: @MainActor (Int) -> Void

    @Environment(\.digiaCampaignKey) private var campaignKey
    @State private var rail = StoryRailState()
    @State private var latestGeometry = StoryRailGeometry()
    @State private var viewportBounds = CGRect.null
    @State private var scrollSettleTask: Task<Void, Never>?
    @State private var lastSettledVisibility: StoryRailVisibility?
    @State private var handedOverKey: String?
    /// Bumps only after the viewer fully closed (post-teardown), never on the overlay flag
    /// flip: the handed-over holder is shared, so a remount while the viewer is alive would
    /// free it from under the viewer.
    @State private var reappearGeneration = 0

    init(
        items: [StoryItemConfig],
        mode: ThumbnailVideoPlaybackMode,
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        cardCornerRadius: CGFloat,
        cardSpacing: CGFloat,
        overlayOpen: Bool,
        prefetch: any MediaPrefetch = NoopMediaPrefetch(),
        onOpenWithHandoff: ((Int, String?) -> Void)? = nil,
        onOpen: @escaping @MainActor (Int) -> Void
    ) {
        self.items = items
        self.mode = mode
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.cardCornerRadius = cardCornerRadius
        self.cardSpacing = cardSpacing
        self.overlayOpen = overlayOpen
        self.prefetch = prefetch
        self.onOpenWithHandoff = onOpenWithHandoff
        self.onOpen = onOpen
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let decision = rail.decision(index: index)
                    let handedOver = handedOverKey == storyPoolKey(
                        namespace: campaignKey, index: index)
                    let playing = decision.play || handedOver
                    ZStack {
                        // Contained media leaves letterbox space. Keep that surface
                        // opaque black across iOS, Android, and Flutter.
                        Color.black
                        if item.type == .video, decision.play || handedOver {
                            StoryThumbnail(
                                item: item,
                                index: index,
                                playing: playing,
                                handedOver: handedOver,
                                repeatWindow: decision.repeatWindow,
                                reappearGeneration: reappearGeneration,
                                namespace: campaignKey,
                                onWindowCompleted: { rail = rail.complete(index: index) },
                                onFailed: { rail = rail.fail(index: index) },
                                onEvicted: { rail = rail.complete(index: index) },
                                onOpen: open
                            )
                        } else {
                            StoryStillCard(item: item, index: index, onOpen: open)
                        }
                    }
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                    .contentShape(Rectangle())
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
            rail = rail
                .lifecycleChanged(active: UIApplication.shared.applicationState == .active)
                .overlayChanged(visible: overlayOpen)
            Task { @MainActor in
                await Task.yield()
                settleVisibility(latestGeometry)
            }
        }
        .task(id: rail.activeIndex) {
            guard let active = rail.activeIndex,
                  items.indices.contains(active),
                  items[active].type == .video
            else { return }
            _ = await prefetch.warmVideoBytes(url: items[active].url, lengthBytes: storyFirstBytes)
        }
        .onChange(of: items) { _ in
            rail = StoryRailState()
                .lifecycleChanged(active: UIApplication.shared.applicationState == .active)
                .overlayChanged(visible: overlayOpen)
            handedOverKey = nil
            lastSettledVisibility = nil
            reappearGeneration &+= 1
            scheduleEligibilityAfterScroll(latestGeometry)
        }
        .onChange(of: overlayOpen) { open in
            rail = rail.overlayChanged(visible: open)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            rail = rail.lifecycleChanged(active: true)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification
        )) { _ in
            rail = rail.lifecycleChanged(active: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .storyViewerDidClose)) { _ in
            // The viewer gave back every holder by now: remount videos so the rail re-borrows
            // and resumes instead of showing a freed (paused) player.
            handedOverKey = nil
            reappearGeneration &+= 1
        }
        .frame(height: cardHeight)
    }

    private func open(index: Int, handoffKey: String?) {
        if handoffKey != nil {
            handedOverKey = handoffKey
        }
        if let onOpenWithHandoff {
            onOpenWithHandoff(index, handoffKey)
        } else {
            onOpen(index)
        }
    }

    private func settleVisibility(_ geometry: StoryRailGeometry) {
        guard let railFrame = geometry.rail,
              !railFrame.isNull,
              !railFrame.isEmpty,
              !geometry.cards.isEmpty,
              !viewportBounds.isNull,
              !viewportBounds.isEmpty else { return }
        let visibility = storyRailVisibility(
            rail: railFrame,
            cards: geometry.cards,
            viewport: viewportBounds
        )
        guard visibility.isMateriallyDifferent(
            from: lastSettledVisibility,
            retaining: rail.eligible
        ) else { return }
        lastSettledVisibility = visibility
        rail = rail.visibilityChanged(
            items: items,
            slotVisible: visibility.slotVisible,
            visibleFractions: visibility.cardFractions,
            settled: true
        )
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

/// A non-playing rail card: its still, tappable to open with no handoff (the viewer
/// builds fresh). The tap lives here — not on the card container — so a playing video
/// keeps its single handoff tap inside `StoryThumbnail` and never opens twice.
@MainActor
private struct StoryStillCard: View {
    let item: StoryItemConfig
    let index: Int
    let onOpen: @MainActor @Sendable (Int, String?) -> Void

    var body: some View {
        StoryThumbnailStill(item: item)
            .contentShape(Rectangle())
            .onTapGesture { onOpen(index, nil) }
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
            return lhs.isNull && rhs.isEmpty
        }
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
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

    /// Handoff for the viewer the next `present` builds: the rail's transfer token when a
    /// playing thumbnail was tapped, else nil. `InlineStoryOverlayState` carries no handoff,
    /// so the opener stashes it here on the same MainActor turn; the overlay reads (and
    /// clears) it at init.
    var pendingHandoffKey: String?

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

        let host = DigiaStoryHostingController(
            rootView: InlineStoryOverlayContent(state: state)
                .environment(\.digiaCampaignKey, state.payload.campaignKey)
        )
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
    // by a UIKit gesture recognizer on this view — a separate UIScreenEdgePan
    // gesture on this view would be starved by SwiftUI's own pan recognizer. This
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
private struct InlineStoryViewerReporter: StoryViewerReporter {
    let payload: CEPTriggerPayload

    func onCompleted(total: Int, timeToCompleteMs: Int64) {
        SDKInstance.shared.reportStoryCompleted(
            payload,
            itemTotal: total,
            timeToCompleteMs: timeToCompleteMs
        )
    }

    func onDismissed(index: Int) {
        SDKInstance.shared.reportStoryStepDismissed(payload, itemIndex: index + 1)
    }
}

@MainActor
private struct InlineStoryOverlayContent: View {
    let state: InlineStoryOverlayState

    @StateObject private var session: StoryViewerSession
    @Environment(\.digiaCampaignKey) private var campaignKey

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
    /// The byte half of the download plan (players borrow through `MediaVideo`). No-op until
    /// lane H lands the real `MediaPrefetch`; the protocol stays the seam either way.
    @State private var planDriver = StoryPlanDriver()
    @State private var firstFrameShown: Bool
    @State private var slowSource = PathSlowNetworkSource()

    init(state: InlineStoryOverlayState) {
        self.state = state
        let initialIndex = min(max(state.initialIndex, 0), max(state.config.items.count - 1, 0))
        let handoffKey = DigiaStoryPresenter.shared.pendingHandoffKey
        DigiaStoryPresenter.shared.pendingHandoffKey = nil
        _session = StateObject(wrappedValue: StoryViewerSession(
            stories: state.config.items,
            startIndex: initialIndex,
            handoffKey: handoffKey,
            restartOnCompleted: state.config.restartOnCompleted,
            startMuted: state.config.startMuted,
            reporter: InlineStoryViewerReporter(payload: state.payload),
            onDismiss: { SDKInstance.shared.controller.dismissStoryOverlay() }
        ))
        _displayedIndex = State(initialValue: initialIndex)
        _firstFrameShown = State(initialValue:
            state.config.items.indices.contains(initialIndex)
                ? state.config.items[initialIndex].type != .video
                : true)
    }

    private var variables: VariableContext {
        buildVariableContext(schemas: state.config.variableSchemas, cepVars: state.payload.variables)
    }

    private var currentIndex: Int { session.currentIndex }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                if let item = currentItem {
                    let muted = session.muted
                    ForEach(renderedIndices, id: \.self) { index in
                        if state.config.items.indices.contains(index) {
                            storyPage(
                                item: state.config.items[index],
                                index: index,
                                active: index == currentIndex,
                                muted: muted
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .opacity(index == displayedIndex ? 1 : 0)
                        }
                    }

                    tapZones

                    VStack(spacing: 0) {
                        StoryProgressBar(
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
                        StoryChrome(
                            closeButton: state.config.closeButton,
                            muteButton: state.config.muteButton,
                            showMute: item.type == .video,
                            muted: muted,
                            onClose: { SDKInstance.shared.controller.dismissStoryOverlay() },
                            onToggleMute: { session.muted.toggle() }
                        )
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
            planDriver.cancelAll()
            if !completed {
                session.dismiss()
            }
            // After every holder is given back, the rail remounts and resumes.
            Task { @MainActor in
                NotificationCenter.default.post(name: .storyViewerDidClose, object: nil)
            }
        }
        .task(id: planInput) {
            drivePlan()
        }
        .onChange(of: currentIndex) { _ in
            resetTiming()
            let isVideo = currentItem?.type == .video
            firstFrameShown = !(isVideo ?? false)
            drivePlan()
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
        storyPageDurationSeconds(item: currentItem, defaultMs: state.config.defaultDuration) ?? 0
    }

    private var progress: Double {
        if currentItem?.type == .video {
            return min(max(videoProgress, 0), 1)
        }
        return min(max(elapsed / max(currentDuration, 0.1), 0), 1)
    }

    private var planInput: String {
        "\(currentIndex)-\(firstFrameShown)-\(session.replayTick)"
    }

    private func drivePlan() {
        let stories = state.config.items.map {
            StoryDownloadPlan.Item(isVideo: $0.type == .video)
        }
        let index = currentIndex
        planDriver.update(
            actions: StoryDownloadPlan.plan(
                stories: stories,
                currentIndex: index,
                firstFrameShown: firstFrameShown,
                slowNetwork: slowSource.isSlow
            ),
            urlOf: { state.config.items[$0].url },
            isVideoOf: { state.config.items[$0].type == .video }
        )
    }

    @ViewBuilder
    private func storyPage(
        item: StoryItemConfig,
        index: Int,
        active: Bool,
        muted: Bool
    ) -> some View {
        // A replay remounts the current page so its video restarts from 0.
        let pageID = index == currentIndex
            ? "\(index)-\(session.replayTick)"
            : "\(index)"
        if item.type == .video {
            VideoStoryPage(
                item: item,
                pageKey: session.pageKey(index: index, namespace: campaignKey),
                muted: muted,
                playing: active && applicationActive,
                onReady: { _ in
                    guard index == currentIndex else { return }
                    videoReady = true
                    displayedIndex = index
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
                    // A broken full-screen item advances, as before.
                    guard index == currentIndex else { return }
                    next()
                }
            )
            .id(pageID)
        } else {
            ImageStoryPage(item: item) {
                guard index == currentIndex else { return }
                videoReady = true
                displayedIndex = index
                firstFrameShown = true
                drivePlan()
            }
            .id(pageID)
        }
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
        // A zero-duration image degrades forward instead of stalling: the frame is skipped
        // at once, never waited on.
        guard let duration = storyPageDurationSeconds(
            item: currentItem, defaultMs: state.config.defaultDuration) else {
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
    }

    private func next() {
        resetTiming()
        if currentIndex < state.config.items.count - 1 {
            move(to: currentIndex + 1)
        } else if state.config.restartOnCompleted {
            move(to: 0)
        } else {
            completed = true
            session.advance()
        }
    }

    private func previous() {
        resetTiming()
        if currentIndex == 0 {
            // Re-show the first story from the top (replayTick remounts its page).
            session.goBack()
        } else {
            move(to: currentIndex - 1)
        }
    }

    private func move(to index: Int) {
        session.showPage(index: index)
        // Navigation must be visible on the tap that changes it. Previously video pages waited
        // for the new player's first frame before updating `displayedIndex`; when going back from
        // page i to i-1 that left page i visible with reset timing, which looked like the current
        // story restarted instead of moving to the previous story. The target video already draws
        // its poster/thumbnail until the player is ready, so switch the visible page immediately.
        displayedIndex = index
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
                campaignKey: state.payload.campaignKey,
                localActionExecutor: LocalActionExecutor(
                    dismiss: { SDKInstance.shared.controller.dismissStoryOverlay() }
                )
            )
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

/// Compat shim for the canvas story viewer (`CampaignCanvasStripViews`, lane I): the pre-T10
/// full-screen video view, behavior-identical. Lane I rewires canvas onto `VideoStoryPage` /
/// `StoryViewer` in W4 (T14); until then this keeps canvas compiling and pixel-identical.
@MainActor
struct InlineStoryVideoView: View {
    let item: StoryItemConfig
    var active: Bool = true
    let muted: Bool
    var onReadyForDisplay: (@MainActor @Sendable () -> Void)?
    var onProgress: (@MainActor @Sendable (Double) -> Void)?
    var onEnded: (@MainActor @Sendable () -> Void)?
    var onBuffering: (@MainActor @Sendable (Bool) -> Void)?
    var onFailed: (@MainActor @Sendable () -> Void)?

    @StateObject private var playback: StoryVideoPlayback
    @Environment(\.digiaCampaignKey) private var campaignKey

    init(
        item: StoryItemConfig,
        active: Bool = true,
        muted: Bool,
        onReadyForDisplay: (@MainActor @Sendable () -> Void)? = nil,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil,
        onEnded: (@MainActor @Sendable () -> Void)? = nil,
        onBuffering: (@MainActor @Sendable (Bool) -> Void)? = nil,
        onFailed: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.item = item
        self.active = active
        self.muted = muted
        self.onReadyForDisplay = onReadyForDisplay
        self.onProgress = onProgress
        self.onEnded = onEnded
        self.onBuffering = onBuffering
        self.onFailed = onFailed
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
        playback.campaignKey = campaignKey
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
                // A broken full-screen item advances unless its caller provides a fallback clock.
                onFailed: {
                    if let onFailed { onFailed() } else { onEnded?() }
                }
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
