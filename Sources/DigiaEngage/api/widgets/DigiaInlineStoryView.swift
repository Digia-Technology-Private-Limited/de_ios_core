import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct DigiaInlineStoryView: View {
    let config: InlineStoryConfig
    let payload: CEPTriggerPayload

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CGFloat(config.card.spacing)) {
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

// MARK: - Dedicated story window presenter

/// Presents the full-screen inline story in its own `UIWindow`, layered above
/// all application (and React Native) content. Using a separate key window —
/// rather than an in-host SwiftUI overlay — means the story owns its touches
/// outright (tap zones, swipe-to-dismiss, CTA) without competing with React
/// Native's Fabric `RCTSurfaceTouchHandler`. Mirrors the isolation Android gets
/// from presenting the story as a `Dialog`.
@MainActor
final class DigiaStoryWindowPresenter {
    static let shared = DigiaStoryWindowPresenter()

    private var window: UIWindow?
    /// The app's key window at present time, restored on dismiss so the host
    /// app's navigation / back gestures keep working after the story closes.
    private weak var previousKeyWindow: UIWindow?

    private init() {}

    func present(state: InlineStoryOverlayState) {
        // Replace any window already showing (e.g. tapping another story).
        dismiss()

        guard let scene = ViewControllerUtil.findWindowScene() else { return }

        previousKeyWindow = scene.windows.first(where: { $0.isKeyWindow })

        let host = DigiaStoryHostingController(rootView: InlineStoryOverlayContent(state: state))
        host.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.backgroundColor = .clear
        // Above normal + alert windows so it covers everything, including any
        // RN-presented content, while still below system UI. Make it key while
        // the story is open so keyboard/back-style commands are routed to the
        // modal story window, then restore the app window on dismiss.
        window.windowLevel = .alert + 1
        self.window = window
        window.makeKeyAndVisible()
    }

    func dismiss() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        // Restore the app's key window so its first-responder-driven gestures
        // (e.g. the interactive pop / back swipe) resume working.
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
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
                                handleCTA(item.ctaAction)
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
            .gesture(
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
        .onChange(of: currentIndex, initial: true) { _, idx in
            SDKInstance.shared.reportStoryStepViewed(
                state.payload,
                itemIndex: idx + 1,
                itemTotal: state.config.items.count
            )
        }
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

    private func handleCTA(_ action: StoryCtaAction?) {
        let label = currentItem?.ctaText.map { interpolate($0, context: variables) }
        let actionUrl = action?.url.map { interpolate($0, context: variables) }
        SDKInstance.shared.reportStoryStepClicked(
            state.payload,
            itemIndex: currentIndex + 1,
            ctaLabel: label,
            actionType: action?.type,
            actionUrl: actionUrl
        )
        switch action?.type {
        case "deepLink", "openUrl":
            if let urlString = actionUrl, let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
            SDKInstance.shared.controller.dismissStoryOverlay()
        default:
            SDKInstance.shared.controller.dismissStoryOverlay()
        }
    }
}

@MainActor
private struct FullScreenStoryItem: View {
    let item: StoryItemConfig
    let onVideoProgress: (Double) -> Void
    let onVideoEnded: () -> Void
    let onVideoBuffering: (Bool) -> Void

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
    var onBuffering: ((Bool) -> Void)?

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
            // DigiaVideoPlaybackBundle.make streams via a resource-loader that
            // forces the content type, so videos served with a non-video
            // Content-Type (e.g. raw.githubusercontent.com) still play —
            // matching Android's ExoPlayer. See DigiaVideoStreaming.
            let nextBundle = DigiaVideoPlaybackBundle.make(url: url, looping: looping)
            nextBundle.player.isMuted = muted

            if let onProgress {
                let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
                timeObserver = nextBundle.player.addPeriodicTimeObserver(
                    forInterval: interval,
                    queue: .main
                ) { time in
                    guard let item = nextBundle.player.currentItem else { return }
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
            if let timeObserver {
                bundle?.player.removeTimeObserver(timeObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            if let failObserver {
                NotificationCenter.default.removeObserver(failObserver)
            }
            bufferingObserver?.invalidate()
            bundle?.player.pause()
        }
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
        player.play()
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
        if index < currentIndex { return 1 }
        if index == currentIndex { return min(max(progress, 0), 1) }
        return 0
    }

    private func backgroundColor(for index: Int) -> Color {
        if index < currentIndex {
            return Color(hex: config.completedColor) ?? Color.white.opacity(0.67)
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(hex: item.ctaTextColor) ?? .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .background(Color(hex: item.ctaBackgroundColor) ?? Color(hex: "#4945FF") ?? .blue)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(item.ctaCornerRadius), style: .continuous))
    }
}
