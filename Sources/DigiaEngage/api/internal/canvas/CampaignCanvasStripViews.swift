@_implementationOnly import SDWebImageSwiftUI
import AVKit
import SwiftUI

/// What the viewer's chrome elements read to draw themselves.
///
/// The chrome is a canvas the author arranged, so its elements are ordinary
/// canvas widgets with no idea they are in a story. This is how a progress strip
/// learns which story is showing, and how a close button learns what to close.
/// Absent outside a viewer — the elements then draw their resting state, which
/// is what the dashboard's own preview wants.
struct CanvasStoryViewerState: Equatable {
    var index = 0
    var pageCount = 1
    /// Elapsed fraction of the current story, 0..1.
    var progress: CGFloat = 0
    var muted = true
}

private struct CanvasStoryViewerKey: EnvironmentKey {
    static let defaultValue: CanvasStoryViewerState? = nil
}
/// A callback the environment can carry.
///
/// SwiftUI environment values must be `Sendable` and a bare closure is not, so
/// the closure is boxed. Unchecked is honest here rather than a shortcut: these
/// are only ever read from a view body, which is main-actor isolated.
struct CanvasStoryCallback: @unchecked Sendable {
    let run: () -> Void
}

private struct CanvasStoryCloseKey: EnvironmentKey {
    static let defaultValue: CanvasStoryCallback? = nil
}
private struct CanvasStoryToggleMuteKey: EnvironmentKey {
    static let defaultValue: CanvasStoryCallback? = nil
}

extension EnvironmentValues {
    var canvasStoryViewer: CanvasStoryViewerState? {
        get { self[CanvasStoryViewerKey.self] }
        set { self[CanvasStoryViewerKey.self] = newValue }
    }
    var canvasStoryClose: CanvasStoryCallback? {
        get { self[CanvasStoryCloseKey.self] }
        set { self[CanvasStoryCloseKey.self] = newValue }
    }
    var canvasStoryToggleMute: CanvasStoryCallback? {
        get { self[CanvasStoryToggleMuteKey.self] }
        set { self[CanvasStoryToggleMuteKey.self] = newValue }
    }
}

/// Resolves an optional campaign colour, falling back when the payload has none.
@MainActor
func canvasColor(_ color: CampaignColor?, _ isDark: Bool, _ fallback: Color) -> Color {
    guard let color else { return fallback }
    return CampaignCanvasTheme.shared.color(color, isDark: isDark)
}

/// The story's media — a still or a looping clip — drawn to fill its box.
///
/// Images go through the same `WebImage` the canvas image widget uses, so a
/// story card and an image widget cache and decode identically.
struct CampaignCanvasRemoteMedia: View {
    let url: String
    let contentMode: ContentMode

    var body: some View {
        // The media story's still, not one of its own. A `.fill` image needs a
        // frame to grow into or it grows the stack around it instead, which is
        // how full-screen story pages ended up with their chrome pushed off the
        // top — `StoryRemoteImage` has always handled that.
        StoryRemoteImage(urlString: url, fit: contentMode == .fit ? .contain : .cover)
    }
}

/// A looping, chrome-free video for a story card or a story's full-screen media.
///
/// `AVPlayer` rather than the canvas video widget's renderer: that one is a
/// configurable player with controls and progress reporting, and a story's media
/// is neither — it plays, it loops, and the viewer's own mute button owns its
/// audio.
/// A chrome-free surface for a player the caller owns.
///
/// The viewer holds the `AVPlayer` rather than this view, because playback is
/// what drives the story's progress bar, its pause and its advance — a player
/// created down here would be invisible to all three.
struct CanvasStoryVideoView: View {
    let player: AVPlayer
    let contentMode: ContentMode

    var body: some View {
        // The media story's player surface: a plain `AVPlayerLayer` in a view
        // that lays it out and never takes a touch. This used to be an
        // `AVPlayerViewController`, which brings a whole view controller and an
        // interactive view per card — `InlineStoryPlayerContainer` documents at
        // length why an interactive video surface breaks the chrome above it.
        InlineStoryPlayerLayer(
            player: player,
            gravity: contentMode == .fit ? .resizeAspect : .resizeAspectFill
        )
    }
}

/// A rail card's media: a still, or a muted looping clip.
///
/// Looping is the rail convention: a card that stopped on its last frame would
/// read as broken next to the ones still playing. Its player is self-contained
/// because nothing outside the card depends on where it is.
struct CanvasStoryRailMedia: View {
    let url: String
    let isVideo: Bool
    let contentMode: ContentMode
    /// Where in the clip the card's poster frame is taken from.
    var posterFrameMs: Int64 = 0

    @StateObject private var playback: StoryVideoPlayback

    init(url: String, isVideo: Bool, contentMode: ContentMode, posterFrameMs: Int64 = 0) {
        self.url = url
        self.isVideo = isVideo
        self.contentMode = contentMode
        self.posterFrameMs = posterFrameMs
        _playback = StateObject(wrappedValue: StoryVideoPlayback(
            urlString: url,
            purpose: .thumbnail(
                canvasStoryItem(url: url, isVideo: isVideo, contentMode: contentMode, posterFrameMs: posterFrameMs)
            )
        ))
    }

    var body: some View {
        // The media story's card, rebuilt from its parts. Black underneath (a
        // player layer has no size of its own), then the poster frame, then the
        // player once it has something to show.
        //
        // That order is the whole point. `InlineStoryPlayerContainer` keeps its
        // layer at `opacity = 0` until `isReadyForDisplay` fires, so a card with
        // nothing behind the player is *blank* for as long as the clip takes to
        // load — which is what a canvas story rail was showing. The media story
        // never had that problem because it always draws a poster first.
        CanvasStoryMediaBackdrop {
            if isVideo {
                if let poster = playback.poster {
                    StoryPosterImage(image: poster, fit: storyFit(contentMode))
                }
                if let player = playback.player {
                    InlineStoryPlayerLayer(
                        player: player,
                        gravity: storyFit(contentMode).videoGravity,
                        // Required, not optional. `revealPlayerIfReady` waits on
                        // `playerLayerReady`, and this callback is the only thing
                        // that ever sets it — so a layer built without it stays
                        // at `showPlayerLayer == false` for ever. The clip loads,
                        // seeks and plays; it is simply never made visible.
                        onReadyForDisplay: playback.playerLayerDidBecomeReady
                    )
                    .opacity(playback.showPlayerLayer ? 1 : 0)
                }
            } else {
                CampaignCanvasRemoteMedia(url: url, contentMode: contentMode)
            }
        }
        .onAppear {
            guard isVideo else { return }
            playback.update(
                // A rail card loops silently until it is tapped: it has no
                // progress of its own to drive and no turn to wait for.
                state: StoryVideoPlaybackState(
                    demand: .playback(.scheduled),
                    active: true,
                    muted: true,
                    repeatWindow: true,
                    restartGeneration: 0
                ),
                events: StoryVideoPlaybackEvents()
            )
        }
        .onDisappear { playback.tearDown() }
    }
}

/// Story media drawn as a backdrop: it fills what it is given and can never
/// change the size of the stack around it.
///
/// The colour is what does it. A player layer has no size of its own and a
/// filling image reports one larger than its box, so media left bare takes the
/// enclosing stack's size with it — which on a full-screen story page pushed the
/// top-aligned chrome and the tap-to-navigate strips out of view. The media
/// story's `FullScreenStoryItem` and its rail card are both built this way.
struct CanvasStoryMediaBackdrop<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .clipped()
    }
}

/// A canvas story page as the media story's item.
///
/// The story video engine is written against `StoryItemConfig` — it reads the
/// url, the media type and where to take a poster from. Mapping here rather than
/// widening that model keeps the two wire formats independent.
func canvasStoryItem(
    url: String,
    isVideo: Bool,
    contentMode: ContentMode,
    posterFrameMs: Int64
) -> StoryItemConfig {
    let fit = storyFit(contentMode)
    return StoryItemConfig(
        type: isVideo ? .video : .image,
        url: url,
        duration: nil,
        thumbnailPlayback: StoryThumbnailPlaybackConfig(startTimeMs: posterFrameMs),
        boxFit: fit,
        thumbnailBoxFit: fit
    )
}

func canvasStoryItem(_ page: CampaignCanvasStoryPage) -> StoryItemConfig {
    let mediaType: StoryMediaType = page.thumbnailIsVideo ? .video : .image
    let boxFit = StoryMediaFit.fromWireValue(page.pageFit, mediaType: mediaType)
    let thumbnailBoxFit = StoryMediaFit.fromWireValue(page.thumbnailFit, mediaType: mediaType)
    return StoryItemConfig(
        type: mediaType,
        url: page.thumbnailUrl,
        duration: Int(max(page.duration, 0) * 1000),
        thumbnailPlayback: StoryThumbnailPlaybackConfig(
            startTimeMs: Int64(page.thumbnailPlayback.startTime * 1000),
            durationMode: page.thumbnailPlayback.fixedDuration ? .fixed : .full,
            durationMs: page.thumbnailPlayback.fixedDuration
                ? Int64(page.thumbnailPlayback.duration * 1000)
                : nil
        ),
        boxFit: boxFit,
        thumbnailBoxFit: thumbnailBoxFit
    )
}

/// The canvas wire's fit vocabulary as the media story's.
func storyFit(_ contentMode: ContentMode) -> StoryMediaFit {
    contentMode == .fit ? .contain : .cover
}

/// Maps the wire's fit vocabulary onto SwiftUI's.
func canvasContentMode(_ fit: String) -> ContentMode {
    fit == "contain" ? .fit : .fill
}

/// Draws a nested canvas at its authored size, scaled uniformly into a box.
///
/// One factor across children, background and typography alike — the same
/// treatment the outer canvas gets from its host, applied one level down.
struct ScaledCanvasStage: View {
    let canvas: CampaignCanvas
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void

    private var scale: CGFloat { canvas.width > 0 ? width / canvas.width : 1 }

    var body: some View {
        CampaignCanvasStage(
            canvas: canvas,
            authoredCornerRadius: 0,
            isDark: isDark,
            showBackground: true,
            onAction: onAction
        )
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: max(0, cornerRadius)))
    }
}

/// Draws a carousel: the current slide, the peek of the next, and the dot row.
///
/// Everything is measured from the widget's own box rather than from the slot,
/// which is what makes the widget composable: the carousel neither knows nor
/// cares whether it sits on an inline card, a nudge or a PiP.
struct CanvasCarouselRenderer: View {
    let widget: CampaignCanvasWidget
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void

    /// Gap above the dots and breathing room below them, matching the dashboard.
    private let indicatorGap: CGFloat = 8
    private let indicatorBottom: CGFloat = 2

    @State private var page = 0
    @State private var timer: Timer?

    var body: some View {
        guard case .carousel(
            _, let slides, let viewportFraction, let itemSpacing,
            let autoPlay, let autoPlayInterval, _,
            let infiniteScroll, let cornerRadius,
            let showIndicator, let dotWidth, let dotHeight, let dotSpacing,
            let dotColor, let activeDotColor, _
        ) = widget, !slides.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            GeometryReader { proxy in
                let indicatorHeight = showIndicator ? indicatorGap + dotHeight + indicatorBottom : 0
                let stripHeight = proxy.size.height - indicatorHeight
                // The spacing is inset around each slide, taking it out of the
                // slide's own width — the same arithmetic the dashboard runs.
                let slideWidth = proxy.size.width * viewportFraction - itemSpacing

                if stripHeight > 0 && slideWidth > 0 {
                    VStack(spacing: 0) {
                        TabView(selection: $page) {
                            ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                                ScaledCanvasStage(
                                    canvas: slide,
                                    width: slideWidth,
                                    height: stripHeight,
                                    cornerRadius: cornerRadius,
                                    isDark: isDark,
                                    onAction: onAction
                                )
                                .frame(maxWidth: .infinity)
                                .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: stripHeight)

                        if showIndicator {
                            HStack(spacing: dotSpacing) {
                                ForEach(Array(slides.enumerated()), id: \.offset) { index, _ in
                                    Capsule()
                                        .fill(
                                            index == page
                                                ? canvasColor(activeDotColor, isDark, Color(red: 0.286, green: 0.271, blue: 1))
                                                : canvasColor(dotColor, isDark, Color(white: 0.8))
                                        )
                                        .frame(width: dotWidth, height: dotHeight)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, indicatorGap)
                            .padding(.bottom, indicatorBottom)
                        }
                    }
                    .onAppear {
                        guard autoPlay, slides.count > 1 else { return }
                        timer = Timer.scheduledTimer(withTimeInterval: autoPlayInterval, repeats: true) { _ in
                            Task { @MainActor in
                                let next = page + 1
                                page = infiniteScroll
                                    ? next % slides.count
                                    : min(next, slides.count - 1)
                            }
                        }
                    }
                    .onDisappear { timer?.invalidate(); timer = nil }
                }
            }
        )
    }
}

/// Draws a story rail, and opens the full-screen viewer when a card is tapped.
///
/// The widget owns both halves of the interaction because both are its own: the
/// rail is what it draws inside its rect, and the viewer is a sheet it presents.
struct CanvasStoryRailRenderer: View {
    let widget: CampaignCanvasWidget
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void

    @State private var openIndex: Int?

    var body: some View {
        guard case .story(
            _, let pages, let cardAspectRatio, let cardCornerRadius, let cardSpacing,
            let showRail, let thumbnailVideoPlayback, let restartOnCompleted, let startMuted, let chrome
        ) = widget, !pages.isEmpty else { return AnyView(EmptyView()) }


        return AnyView(
            GeometryReader { proxy in
                // Nothing renders when the rail is off: the stories are opened by
                // an `Action.showStory` elsewhere on the canvas. The widget still
                // has to be here, because it carries the stories and the chrome.
                if showRail {
                    // A card is as tall as the rail's own box, so its width
                    // follows from the authored ratio. Nothing reads a card-height
                    // property, because there isn't one.
                    let cardWidth = proxy.size.height * cardAspectRatio
                    StoryThumbnailRailView(
                        items: pages.map(canvasStoryItem),
                        mode: thumbnailVideoPlayback.asInlineStoryMode,
                        cardWidth: cardWidth,
                        cardHeight: proxy.size.height,
                        cardCornerRadius: cardCornerRadius,
                        cardSpacing: cardSpacing,
                        overlayOpen: openIndex != nil
                    ) { index in
                        openIndex = index
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { openIndex != nil },
                set: { if !$0 { openIndex = nil } }
            )) {
                CanvasStoryViewer(
                    pages: pages,
                    chrome: chrome,
                    initialIndex: openIndex ?? 0,
                    restartOnCompleted: restartOnCompleted,
                    startMuted: startMuted,
                    isDark: isDark,
                    onAction: onAction,
                    onDismiss: { openIndex = nil }
                )
            }
        )
    }
}

private extension CampaignCanvasStoryThumbnailPlaybackMode {
    var asInlineStoryMode: ThumbnailVideoPlaybackMode {
        switch self {
        case .simultaneous: .simultaneous
        case .sequential: .sequential
        }
    }
}

/// Full-screen canvas story player: the story's media, the authored overlay, the
/// chrome the author arranged, tap-to-navigate, hold-to-pause and auto-advance.
///
/// The playback engine mirrors the media story's: a video drives its own
/// progress and duration, a long press pauses it, and muting changes the live
/// player's volume rather than rebuilding it. The first version ran a single
/// timer regardless of the media, so a 30-second clip was cut off after the
/// story's authored 5 and a hold did nothing.
struct CanvasStoryViewer: View {
    let pages: [CampaignCanvasStoryPage]
    let chrome: CampaignCanvas
    let initialIndex: Int
    let restartOnCompleted: Bool
    let startMuted: Bool
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    let onDismiss: () -> Void

    @State private var index = 0
    @State private var progress: CGFloat = 0
    @State private var muted = true
    @State private var paused = false
    @State private var ticker: Timer?
    @State private var player: AVPlayer?
    /// Set once the clip reports a real duration; until then the story runs on
    /// its authored one, which is also the fallback for an unplayable video.
    @State private var videoDuration: TimeInterval?

    private var page: CampaignCanvasStoryPage { pages[min(max(0, index), pages.count - 1)] }

    var body: some View {
        GeometryReader { proxy in
            // No black plate in this stack: the media backdrop below is opaque
            // and already covers the screen. One here would sit *over* the
            // backdrop — a background draws behind its parent's content — and
            // hide the story's own media behind a black rectangle.
            ZStack(alignment: .top) {
                // Navigation sits under the chrome and over the page, so a
                // button the author placed on a page still wins the tap.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { step(-1) }
                    Color.clear.contentShape(Rectangle()).onTapGesture { step(1) }
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.2)
                        .onChanged { _ in pause() }
                        .onEnded { _ in resume() }
                )

                // Both the overlay and the chrome are authored against the safe
                // region, so both draw at the same scale and inside it.
                let scale = page.canvas.width > 0 ? proxy.size.width / page.canvas.width : 1
                VStack {
                    Spacer(minLength: 0)
                    ScaledCanvasStage(
                        canvas: page.canvas,
                        width: proxy.size.width,
                        height: page.canvas.height * scale,
                        cornerRadius: 0,
                        isDark: isDark,
                        onAction: onAction
                    )
                }

                ScaledCanvasStage(
                    canvas: chrome,
                    width: proxy.size.width,
                    height: chrome.height * scale,
                    cornerRadius: 0,
                    isDark: isDark,
                    onAction: onAction
                )
                .environment(
                    \.canvasStoryViewer,
                    CanvasStoryViewerState(
                        index: index,
                        pageCount: pages.count,
                        progress: progress,
                        muted: muted
                    )
                )
                .environment(\.canvasStoryClose, CanvasStoryCallback(run: onDismiss))
                .environment(
                    \.canvasStoryToggleMute,
                    CanvasStoryCallback(run: { toggleMute() })
                )
            }
            // The screen, and only the screen. Without this the stack takes its
            // size from its largest child, and a story's media is routinely
            // larger than the screen — a filling image reports an ideal size in
            // the image's own pixels. That grew the stack, which carried the
            // top-aligned chrome above the top edge and the bottom-anchored page
            // canvas below the bottom one.
            .frame(width: proxy.size.width, height: proxy.size.height)
            // The media goes here rather than in the stack for the same reason:
            // a background is measured against its parent and can never resize
            // it, however large the image inside turns out to be. It still
            // bleeds under the status bar and the home indicator, because a
            // story's media is the screen.
            .background {
                CanvasStoryMediaBackdrop {
                    if !page.thumbnailUrl.isEmpty {
                        if page.thumbnailIsVideo, let player {
                            CanvasStoryVideoView(
                                player: player,
                                contentMode: canvasContentMode(page.pageFit)
                            )
                        } else if !page.thumbnailIsVideo {
                            CampaignCanvasRemoteMedia(
                                url: page.thumbnailUrl,
                                contentMode: canvasContentMode(page.pageFit)
                            )
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            index = min(max(0, initialIndex), pages.count - 1)
            muted = startMuted
            start()
        }
        .onDisappear { stop() }
    }

    /// Advances or rewinds, restarting the elapsed bar either way.
    private func step(_ delta: Int) {
        // Restarting the current story before stepping back is the story
        // convention: a tap on the left means "I missed that", and on the first
        // story there is nothing behind to go to.
        if delta < 0 && (progress > 0.15 || index == 0) { start(); return }
        let next = index + delta
        if next < 0 { start(); return }
        if next >= pages.count {
            if restartOnCompleted { index = 0; start() } else { onDismiss() }
            return
        }
        index = next
        start()
    }

    private func pause() {
        guard !paused else { return }
        paused = true
        player?.pause()
    }

    private func resume() {
        guard paused else { return }
        paused = false
        player?.play()
    }

    private func toggleMute() {
        muted.toggle()
        // Volume on the live player rather than a rebuild, which is what made
        // muting restart the clip from zero.
        player?.isMuted = muted
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        player?.pause()
        player = nil
        videoDuration = nil
    }

    private func start() {
        stop()
        progress = 0
        paused = false

        let current = page
        if current.thumbnailIsVideo, !current.thumbnailUrl.isEmpty,
           let url = URL(string: current.thumbnailUrl) {
            let item = AVPlayer(url: url)
            item.isMuted = muted
            item.play()
            player = item
        }

        let interval = 1.0 / 30.0
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                guard !paused else { return }
                if let player, let duration = player.currentItem?.duration.seconds,
                   duration.isFinite, duration > 0 {
                    // The clip's own length wins once it is known, so a story
                    // ends when the video does rather than on a guess.
                    videoDuration = duration
                    progress = CGFloat(player.currentTime().seconds / duration)
                } else {
                    progress += CGFloat(interval / max(0.1, current.duration))
                }
                if progress >= 1 { step(1) }
            }
        }
    }
}

/// Draws the viewer's progress strip; see `CanvasStoryViewerState`.
struct CanvasStoryProgressRenderer: View {
    let activeColor: CampaignColor?
    let trackColor: CampaignColor?
    let barHeight: CGFloat
    let cornerRadius: CGFloat
    let gap: CGFloat
    let isDark: Bool

    @Environment(\.canvasStoryViewer) private var viewer

    var body: some View {
        let count = max(1, viewer?.pageCount ?? 1)
        let active = viewer?.index ?? 0
        let elapsed = viewer?.progress ?? 0
        HStack(spacing: gap) {
            ForEach(0..<count, id: \.self) { segment in
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(canvasColor(trackColor, isDark, Color.white.opacity(0.35)))
                        // Stories already seen read as full, the current one
                        // animates, and the rest stay empty — the shape of the
                        // strip is what tells the viewer where they are.
                        let fraction: CGFloat = segment < active
                            ? 1
                            : (segment == active ? min(max(elapsed, 0), 1) : 0)
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(canvasColor(activeColor, isDark, .white))
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: barHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// The button both chrome icons share. Fills its rect and rounds its corners to
/// half the shorter side — a circle when the author draws a square box, a pill
/// when they do not. There is no size property to disagree with the rect.
///
/// It used to be a `Circle`, which inscribes itself in the box and centres: a
/// wide element authored in the dashboard rendered here as a small circle.
struct CanvasStoryChromeButton: View {
    enum Kind { case close, mute }
    let kind: Kind
    let visible: Bool
    let iconColor: CampaignColor?
    let backgroundColor: CampaignColor?
    let isDark: Bool

    @Environment(\.canvasStoryViewer) private var viewer
    @Environment(\.canvasStoryClose) private var close
    @Environment(\.canvasStoryToggleMute) private var toggleMute

    var body: some View {
        if visible {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                ZStack {
                    Capsule().fill(canvasColor(backgroundColor, isDark, Color.black.opacity(0.35)))
                    Image(systemName: symbol)
                        .font(.system(size: side * 0.5, weight: .medium))
                        .foregroundColor(canvasColor(iconColor, isDark, .white))
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Capsule())
                .onTapGesture { (kind == .close ? close : toggleMute)?.run() }
            }
        }
    }

    private var symbol: String {
        switch kind {
        case .close: "xmark"
        case .mute: (viewer?.muted ?? true) ? "speaker.slash.fill" : "speaker.wave.2.fill"
        }
    }
}
