import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct DigiaInlineStoryView: View {
    let config: InlineStoryConfig
    let payload: CEPTriggerPayload

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Match Android's LazyRow: an eager HStack creates an AVPlayerLooper
            // for every video in the campaign, including cards far off-screen.
            // That can exhaust the simulator/device media pipeline before the
            // user has interacted with a single story.
            LazyHStack(spacing: CGFloat(config.card.spacing)) {
                ForEach(Array(config.items.enumerated()), id: \.offset) { index, item in
                    StoryThumbnailCard(item: item, config: config)
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
    }
}

@MainActor
private struct StoryThumbnailCard: View {
    let item: StoryItemConfig
    let config: InlineStoryConfig

    private var width: CGFloat {
        CGFloat(config.card.height) * CGFloat(config.card.aspectRatio)
    }

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.10)
            if item.type == "video" {
                InlineStoryVideoView(urlString: item.url, looping: true, muted: true)
            } else {
                StoryRemoteImage(urlString: item.url)
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

    init(state: InlineStoryOverlayState) {
        self.state = state
        _currentIndex = State(initialValue: min(max(state.initialIndex, 0), max(state.config.items.count - 1, 0)))
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
                    FullScreenStoryItem(
                        item: item,
                        onVideoProgress: { videoProgress = $0 },
                        onVideoEnded: { next() },
                        onVideoBuffering: { videoBuffering = $0 }
                    )
                        .id(currentIndex)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

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

    private var currentDuration: Double {
        let ms = currentItem?.duration ?? state.config.defaultDuration
        return max(Double(ms) / 1000.0, 0.1)
    }

    private var progress: Double {
        if currentItem?.type == "video" {
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
        if item.type == "video" {
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
            currentIndex += 1
        } else if state.config.restartOnCompleted {
            currentIndex = 0
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
        currentIndex = max(currentIndex - 1, 0)
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
    let onVideoProgress: (Double) -> Void
    let onVideoEnded: () -> Void
    let onVideoBuffering: @Sendable (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black
            if item.type == "video" {
                InlineStoryVideoView(
                    urlString: item.url,
                    looping: false,
                    muted: false,
                    gravity: .resizeAspect,
                    onProgress: onVideoProgress,
                    onEnded: onVideoEnded,
                    onBuffering: onVideoBuffering
                )
            } else {
                // Letterbox (never crop): show the whole image, bars where aspect differs.
                StoryRemoteImage(urlString: item.url, contentMode: .fit)
            }
        }
    }
}

@MainActor
private struct StoryRemoteImage: View {
    let urlString: String
    /// `.fill` crops to fill (story thumbnails); `.fit` letterboxes (full-screen).
    var contentMode: ContentMode = .fill

    var body: some View {
        if let url = URL(string: urlString) {
            DigiaCachedImageView(
                url: url,
                placeholder: AnyView(Color(red: 0.10, green: 0.10, blue: 0.10))
            )
            .aspectRatio(contentMode: contentMode)
        } else {
            Color(red: 0.16, green: 0.16, blue: 0.16)
        }
    }
}

@MainActor
private struct InlineStoryVideoView: View {
    let urlString: String
    let looping: Bool
    let muted: Bool
    /// Aspect-fill for thumbnails (crop to fill), aspect-fit for full-screen.
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    /// Full-screen playback hooks; thumbnails leave these nil and skip the
    /// observers entirely.
    var onProgress: ((Double) -> Void)?
    var onEnded: (() -> Void)?
    var onBuffering: (@Sendable (Bool) -> Void)?

    @State private var bundle: DigiaVideoPlaybackBundle?
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var failObserver: NSObjectProtocol?
    @State private var bufferingObserver: NSKeyValueObservation?

    var body: some View {
        ZStack {
            Color.black
            if let player = bundle?.player {
                InlineStoryPlayerLayer(player: player, gravity: gravity)
            }
        }
        .task(id: "\(urlString)-\(looping)-\(muted)") {
            guard let url = URL(string: urlString) else { return }
            tearDownPlayback()

            // DigiaVideoPlaybackBundle overrides an incorrect server MIME type
            // while leaving HTTP transport/range handling to AVFoundation on
            // supported OS versions. See DigiaVideoStreaming.
            let nextBundle = DigiaVideoPlaybackBundle.make(url: url, looping: looping)
            nextBundle.player.isMuted = muted

            if let onProgress {
                let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
                timeObserver = nextBundle.player.addPeriodicTimeObserver(
                    forInterval: interval,
                    queue: .main
                ) { [weak player = nextBundle.player] time in
                    guard let item = player?.currentItem else { return }
                    let duration = item.duration.seconds
                    guard duration.isFinite, duration > 0 else { return }
                    onProgress(min(max(time.seconds / duration, 0), 1))
                }
            }
            if let onEnded {
                // Advance on natural completion or on an unplayable item, so a
                // broken URL doesn't leave the story stuck on a black frame.
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: nextBundle.player.currentItem,
                    queue: .main
                ) { _ in onEnded() }
                failObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: nextBundle.player.currentItem,
                    queue: .main
                ) { _ in onEnded() }
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
            nextBundle.player.play()
        }
        .onDisappear {
            tearDownPlayback()
        }
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

        bundle.looper?.disableLooping()
        bundle.player.pause()
        if let queuePlayer = bundle.player as? AVQueuePlayer {
            queuePlayer.removeAllItems()
        } else {
            bundle.player.replaceCurrentItem(with: nil)
        }

        timeObserver = nil
        endObserver = nil
        failObserver = nil
        bufferingObserver = nil
        self.bundle = nil
    }
}

private struct InlineStoryPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context _: Context) -> InlineStoryPlayerContainer {
        let view = InlineStoryPlayerContainer()
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ uiView: InlineStoryPlayerContainer, context _: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = gravity
    }

    static func dismantleUIView(_ uiView: InlineStoryPlayerContainer, coordinator _: Void) {
        uiView.playerLayer.player = nil
    }
}

private final class InlineStoryPlayerContainer: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
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
