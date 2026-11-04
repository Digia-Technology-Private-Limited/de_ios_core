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
    /// Overrides the real prefetch (tests); nil warms through `DefaultMediaPrefetch`.
    let prefetch: (any MediaPrefetch)?
    let onOpenWithHandoff: ((Int, String?) -> Void)?
    let onOpen: @MainActor (Int) -> Void

    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.mediaServices) private var mediaServices
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
        prefetch: (any MediaPrefetch)? = nil,
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
            let warm = prefetch
                ?? DefaultMediaPrefetch(campaignKey: campaignKey, services: mediaServices)
            _ = await warm.warmVideoBytes(url: items[active].url, lengthBytes: storyFirstBytes)
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
    private let entry: StoryViewerEntry

    init(state: InlineStoryOverlayState) {
        self.state = state
        let initialIndex = min(max(state.initialIndex, 0), max(state.config.items.count - 1, 0))
        let handoffKey = DigiaStoryPresenter.shared.pendingHandoffKey
        DigiaStoryPresenter.shared.pendingHandoffKey = nil
        let payload = state.payload
        let total = state.config.items.count
        self.entry = StoryViewerEntry(
            stories: state.config.items,
            startIndex: initialIndex,
            handoffKey: handoffKey,
            restartOnCompleted: state.config.restartOnCompleted,
            startMuted: state.config.startMuted,
            defaultDurationMs: state.config.defaultDuration,
            reporter: InlineStoryViewerReporter(payload: payload),
            onDismiss: { SDKInstance.shared.controller.dismissStoryOverlay() },
            // Step Viewed fires for each frame that becomes visible (including the first),
            // mirroring Android's LaunchedEffect(currentStoryIndex).
            onPageShown: { index in
                SDKInstance.shared.reportStoryStepViewed(
                    payload, itemIndex: index + 1, itemTotal: total)
            },
            tapLayout: .edges(width: 88),
            // A looping inline story is not a completion in its funnel.
            reportsCompletionOnLoop: false
        )
    }

    var body: some View {
        // Dismissal gestures live in a single SwiftUI DragGesture so they don't fight a
        // separate UIKit recognizer (which SwiftUI's own pan would starve). Two "back"
        // affordances:
        //   • swipe DOWN  — standard full-screen-cover dismissal
        //   • swipe RIGHT from the left edge — iOS interactive "back"
        // `simultaneousGesture` (not `gesture`) so this doesn't claim exclusive recognition
        // over the left/right tap zones beneath it — a plain `.gesture()` here was swallowing
        // taps meant for story navigation.
        StoryViewer(entry: entry) { viewer in
            InlineStoryChrome(state: state, viewer: viewer)
        }
        .contentShape(Rectangle())
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
}

/// The inline viewer's chrome over the shared pages: progress strip, CTA, close and mute.
@MainActor
private struct InlineStoryChrome: View {
    let state: InlineStoryOverlayState
    let viewer: StoryViewerContext

    private var variables: VariableContext {
        buildVariableContext(schemas: state.config.variableSchemas, cepVars: state.payload.variables)
    }

    var body: some View {
        let item = viewer.item
        ZStack {
            VStack(spacing: 0) {
                StoryProgressBar(
                    totalItems: viewer.count,
                    currentIndex: viewer.index,
                    progress: viewer.progress,
                    config: state.config.indicator
                )
                // `proxy.safeAreaInsets` is zero in the viewer because its GeometryReader
                // ignores the safe area for full-bleed media, so we source the real device
                // insets from the window instead (see `safeAreaInsets`).
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
                    muted: viewer.muted,
                    onClose: { SDKInstance.shared.controller.dismissStoryOverlay() },
                    onToggleMute: viewer.toggleMute
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

    /// Real device safe-area insets, read from the active window. The viewer's GeometryReader
    /// uses `.ignoresSafeArea()` for full-bleed media, which makes its own `safeAreaInsets`
    /// report zero — so the progress bar (and CTA) would otherwise sit under the notch / home
    /// indicator.
    private var safeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .map(\.safeAreaInsets)
            .first(where: { $0.top > 0 }) ?? .zero
    }

    private func handleCTA(_ item: StoryItemConfig) {
        let actions = item.actions
        let reportedAction = actions.first?.resolved(with: variables)
        let label = item.ctaText.map { interpolate($0, context: variables) }
        SDKInstance.shared.reportStoryStepClicked(
            state.payload,
            itemIndex: viewer.index + 1,
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
