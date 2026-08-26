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

/// Cached, poster-backed media for canvas story surfaces.
struct CanvasStoryCachedMedia: View {
    let url: String
    let isVideo: Bool
    let contentMode: ContentMode
    var autoplay = true
    var loop = true
    var muted = true
    var showControls = false
    /// Where in the clip the card's poster frame is taken from.
    var posterFrameMs: Int64 = 0

    @StateObject private var playback: StoryVideoPlayback
    @State private var controllerReady = false

    init(
        url: String,
        isVideo: Bool,
        contentMode: ContentMode,
        posterFrameMs: Int64 = 0,
        autoplay: Bool = true,
        loop: Bool = true,
        muted: Bool = true,
        showControls: Bool = false
    ) {
        self.url = url
        self.isVideo = isVideo
        self.contentMode = contentMode
        self.posterFrameMs = posterFrameMs
        self.autoplay = autoplay
        self.loop = loop
        self.muted = muted
        self.showControls = showControls
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
                    if showControls {
                        CanvasPlayerController(
                            player: player,
                            controls: true,
                            gravity: storyFit(contentMode).videoGravity,
                            onReadyForDisplay: {
                                controllerReady = true
                                playback.playerLayerDidBecomeReady()
                            }
                        )
                        .opacity(controllerReady ? 1 : 0)
                    } else {
                        InlineStoryPlayerLayer(
                            player: player,
                            gravity: storyFit(contentMode).videoGravity,
                            onReadyForDisplay: playback.playerLayerDidBecomeReady
                        )
                        .opacity(playback.showPlayerLayer ? 1 : 0)
                    }
                }
            } else {
                CampaignCanvasRemoteMedia(url: url, contentMode: contentMode)
            }
        }
        .onAppear {
            guard isVideo else { return }
            playback.update(
                state: StoryVideoPlaybackState(
                    demand: .playback(.scheduled),
                    active: autoplay,
                    muted: muted,
                    repeatWindow: loop,
                    restartGeneration: 0,
                    rewindOnEnd: loop,
                    repeatWhenInactive: showControls
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
    let boxFit: StoryMediaFit = page.pageFit == "fill"
        ? .fill
        : StoryMediaFit.fromWireValue(page.pageFit, mediaType: mediaType)
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

    @State private var scrollPosition: Int?
    @State private var timer: Timer?
    /// True while the last page change came from the autoplay timer rather than the user's finger,
    /// which is the distinction the legacy carousel's `auto` flag draws.
    @State private var advancedAutomatically = false
    @State private var isRecentering = false
    @State private var lastReportedDisplayIndex: Int?
    @Environment(\.canvasInteractions) private var reportInteraction

    private func realIndex(_ displayIndex: Int, slideCount: Int, loopEnabled: Bool) -> Int {
        guard loopEnabled else { return displayIndex }
        return (((displayIndex - 1) % slideCount) + slideCount) % slideCount
    }

    var body: some View {
        guard case .carousel(
            _, let slides, let viewportFraction, let itemSpacing,
            let autoPlay, let autoPlayInterval, let animationDuration,
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
                    let loopEnabled = infiniteScroll && slides.count > 1
                    let displayCount = loopEnabled ? slides.count + 2 : slides.count
                    let initialDisplayIndex = loopEnabled ? 1 : 0
                    let activeIndex = realIndex(
                        scrollPosition ?? initialDisplayIndex,
                        slideCount: slides.count,
                        loopEnabled: loopEnabled
                    )

                    VStack(spacing: 0) {
                        if #available(iOS 17, *) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: itemSpacing) {
                                    ForEach(0 ..< displayCount, id: \.self) { displayIndex in
                                        let index = realIndex(
                                            displayIndex,
                                            slideCount: slides.count,
                                            loopEnabled: loopEnabled
                                        )
                                        ScaledCanvasStage(
                                            canvas: slides[index],
                                            width: slideWidth,
                                            height: stripHeight,
                                            cornerRadius: cornerRadius,
                                            isDark: isDark,
                                            // The slide an action came from travels with it, so the
                                            // host can tell a tap on slide 3 from a tap on the card
                                            // around it.
                                            onAction: { request in
                                                var stamped = request
                                                stamped.step = CanvasStep(
                                                    kind: .carouselSlide,
                                                    index: index,
                                                    total: slides.count
                                                )
                                                onAction(stamped)
                                            }
                                        )
                                        .id(displayIndex)
                                    }
                                }
                                .scrollTargetLayout()
                            }
                            .contentMargins(
                                .horizontal,
                                max(0, (proxy.size.width - slideWidth) / 2),
                                for: .scrollContent
                            )
                            .scrollPosition(id: $scrollPosition)
                            .scrollTargetBehavior(.viewAligned)
                            .frame(height: stripHeight)
                            // A slide is viewed when it comes to rest. The first visible slide is
                            // reported on appear too, matching the legacy carousel.
                            .onAppear {
                                if scrollPosition == nil {
                                    scrollPosition = initialDisplayIndex
                                }
                                reportSlide(
                                    displayIndex: scrollPosition ?? initialDisplayIndex,
                                    slideCount: slides.count,
                                    loopEnabled: loopEnabled,
                                    auto: false
                                )
                                startAutoPlay(
                                    autoPlay: autoPlay,
                                    autoPlayInterval: autoPlayInterval,
                                    animationDuration: animationDuration,
                                    displayCount: displayCount,
                                    slideCount: slides.count,
                                    loopEnabled: loopEnabled
                                )
                            }
                            .onDisappear { stopAutoPlay() }
                            .onChange(of: scrollPosition) { _, newValue in
                                guard let displayIndex = newValue else { return }
                                if isRecentering {
                                    isRecentering = false
                                    return
                                }

                                reportSlide(
                                    displayIndex: displayIndex,
                                    slideCount: slides.count,
                                    loopEnabled: loopEnabled,
                                    auto: advancedAutomatically
                                )
                                advancedAutomatically = false

                                if loopEnabled, displayIndex == 0 || displayIndex == displayCount - 1 {
                                    let target = displayIndex == 0 ? displayCount - 2 : 1
                                    isRecentering = true
                                    DispatchQueue.main.async {
                                        var transaction = Transaction()
                                        transaction.disablesAnimations = true
                                        withTransaction(transaction) {
                                            scrollPosition = target
                                        }
                                    }
                                }
                            }
                        } else {
                            EmptyView()
                        }

                        if showIndicator {
                            HStack(spacing: dotSpacing) {
                                ForEach(Array(slides.enumerated()), id: \.offset) { index, _ in
                                    Capsule()
                                        .fill(
                                            index == activeIndex
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
                }
            }
        )
    }

    private func reportSlide(
        displayIndex: Int,
        slideCount: Int,
        loopEnabled: Bool,
        auto: Bool
    ) {
        guard lastReportedDisplayIndex != displayIndex else { return }
        lastReportedDisplayIndex = displayIndex
        reportInteraction(
            .carouselSlideViewed(
                index: realIndex(displayIndex, slideCount: slideCount, loopEnabled: loopEnabled),
                total: slideCount,
                auto: auto
            )
        )
    }

    private func startAutoPlay(
        autoPlay: Bool,
        autoPlayInterval: TimeInterval,
        animationDuration: TimeInterval,
        displayCount: Int,
        slideCount: Int,
        loopEnabled: Bool
    ) {
        stopAutoPlay()
        guard autoPlay, slideCount > 1 else { return }
        let timer = Timer(timeInterval: autoPlayInterval, repeats: true) { _ in
            Task { @MainActor in
                let current = scrollPosition ?? (loopEnabled ? 1 : 0)
                if !loopEnabled && current >= displayCount - 1 { return }
                let next = min(current + 1, displayCount - 1)
                // Flagged before the change, so the `onChange` it triggers knows
                // the slide arrived on a timer rather than under a finger.
                advancedAutomatically = true
                withAnimation(.easeInOut(duration: animationDuration)) {
                    scrollPosition = next
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAutoPlay() {
        timer?.invalidate()
        timer = nil
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
    @Environment(\.canvasInteractions) private var reportInteraction

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
                .onAppear {
                    reportInteraction(
                        .storyOpened(index: openIndex ?? 0, total: pages.count)
                    )
                }
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
private struct CanvasStoryMediaKey: Hashable {
    let index: Int
    let generation: Int
}

struct CanvasStoryViewer: View {
    let pages: [CampaignCanvasStoryPage]
    let chrome: CampaignCanvas
    let initialIndex: Int
    let restartOnCompleted: Bool
    let startMuted: Bool
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    let onDismiss: () -> Void
    /// Whether to draw the authored page and chrome layers over the media backdrop.
    /// Floater stories suppress these while their media aperture is moving.
    var showsOverlays = true
    /// The unsafe margins of the region this viewer was handed, when the caller
    /// draws it somewhere that does not carve them out on its own.
    ///
    /// A `fullScreenCover` presents its content inside the safe area, so the
    /// reader below already reports the safe region and these stay `.zero` —
    /// that is the story rail's path. The floater's story is drawn inline in
    /// `DigiaHost`'s full-bleed overlay layer instead, which is deliberately
    /// `ignoresSafeArea()` so the collapsed window can sit anywhere on the
    /// screen; nothing there insets this viewer, so the caller passes the
    /// device's own insets and they are applied below.
    var safeAreaInsets = EdgeInsets()

    @State private var index = 0
    @State private var progress: CGFloat = 0
    @State private var muted = true
    @State private var paused = false
    @State private var ticker: Timer?
    @State private var playbackGeneration = 0
    @State private var displayedMediaKey = CanvasStoryMediaKey(index: 0, generation: 0)

    // ── analytics ──
    //
    // Reported from the viewer rather than the rail, because the rail cannot see any of it: a page
    // advances on a timer, a tap or a video ending, and only this view knows which page is showing.
    @Environment(\.canvasInteractions) private var reportInteraction
    @State private var openedAt = Date()
    @State private var completedReported = false

    private var page: CampaignCanvasStoryPage { pages[min(max(0, index), pages.count - 1)] }
    private var currentMediaKey: CanvasStoryMediaKey {
        CanvasStoryMediaKey(index: index, generation: playbackGeneration)
    }

    private var renderedMediaKeys: [CanvasStoryMediaKey] {
        displayedMediaKey == currentMediaKey
            ? [currentMediaKey]
            : [displayedMediaKey, currentMediaKey]
    }

    var body: some View {
        GeometryReader { proxy in
            // The width the chrome and the page are scaled against: the reader
            // minus any margin the caller declared unsafe. Zero on the presented
            // path, where the reader is already the safe region, so that path
            // scales exactly as it always did.
            let contentWidth = max(
                0, proxy.size.width - safeAreaInsets.leading - safeAreaInsets.trailing
            )
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
                .allowsHitTesting(showsOverlays)
                .accessibilityHidden(!showsOverlays)

                // Both the overlay and the chrome are authored against the safe
                // region, so both draw at the same scale and inside it.
                let scale = page.canvas.width > 0 ? contentWidth / page.canvas.width : 1
                // The page an action came from travels with it, so a CTA inside story 3 reports as
                // a step click on story 3 rather than as an anonymous click on the card.
                let pageAction: (CampaignCanvasActionRequest) -> Void = { request in
                    var stamped = request
                    stamped.step = CanvasStep(
                        kind: .storyPage, index: index, total: pages.count
                    )
                    onAction(stamped)
                }
                VStack {
                    Spacer(minLength: 0)
                    ScaledCanvasStage(
                        canvas: page.canvas,
                        width: contentWidth,
                        height: page.canvas.height * scale,
                        cornerRadius: 0,
                        isDark: isDark,
                        onAction: pageAction
                    )
                }
                .opacity(showsOverlays ? 1 : 0)
                .allowsHitTesting(showsOverlays)
                .accessibilityHidden(!showsOverlays)

                ScaledCanvasStage(
                    canvas: chrome,
                    width: contentWidth,
                    height: chrome.height * scale,
                    cornerRadius: 0,
                    isDark: isDark,
                    onAction: pageAction
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
                .environment(\.canvasStoryClose, CanvasStoryCallback(run: dismissWithReport))
                .environment(
                    \.canvasStoryToggleMute,
                    CanvasStoryCallback(run: { toggleMute() })
                )
                .opacity(showsOverlays ? 1 : 0)
                .allowsHitTesting(showsOverlays)
                .accessibilityHidden(!showsOverlays)
            }
            // Inside the safe region, and the backdrop below outside it. The
            // padding is *inside* the frame that follows, so the stack is offered
            // the reader minus these insets while the frame — and so the media
            // behind it — still covers the whole reader.
            .padding(safeAreaInsets)
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
                    ZStack {
                        ForEach(renderedMediaKeys, id: \.self) { mediaKey in
                            let mediaPage = pages[mediaKey.index]
                            if mediaPage.thumbnailIsVideo, !mediaPage.thumbnailUrl.isEmpty {
                                InlineStoryVideoView(
                                    item: canvasStoryItem(mediaPage),
                                    active: mediaKey == currentMediaKey && !paused,
                                    muted: muted,
                                    onReadyForDisplay: {
                                        guard mediaKey == currentMediaKey else { return }
                                        displayedMediaKey = mediaKey
                                    },
                                    onProgress: {
                                        guard mediaKey == currentMediaKey,
                                              mediaKey == displayedMediaKey else { return }
                                        progress = CGFloat($0)
                                    },
                                    onEnded: {
                                        guard mediaKey == currentMediaKey else { return }
                                        step(1)
                                    },
                                    onFailed: {
                                        guard mediaKey == currentMediaKey else { return }
                                        displayedMediaKey = mediaKey
                                        startAuthoredTimer()
                                    }
                                )
                                .id(mediaKey)
                                .opacity(mediaKey == displayedMediaKey ? 1 : 0)
                            } else if !mediaPage.thumbnailUrl.isEmpty {
                                CampaignCanvasRemoteMedia(
                                    url: mediaPage.thumbnailUrl,
                                    contentMode: canvasContentMode(mediaPage.pageFit)
                                )
                                .opacity(mediaKey == displayedMediaKey ? 1 : 0)
                            }
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            index = min(max(0, initialIndex), pages.count - 1)
            muted = startMuted
            openedAt = Date()
            reportInteraction(.storyPageViewed(index: index, total: pages.count))
            start(retainingDisplayedMedia: false)
        }
        .onChange(of: index) { newIndex in
            reportInteraction(.storyPageViewed(index: newIndex, total: pages.count))
        }
        .onDisappear { stop() }
    }

    /// Advances or rewinds, restarting the elapsed bar either way.
    private func step(_ delta: Int) {
        let next = index + delta
        // A tap on the left goes back a page, every single time. It used to
        // restart the current page instead whenever more than 15% of it had
        // elapsed — the "I missed that" convention — which in practice meant it
        // never went back at all: a page runs for seconds, so all but the very
        // first frames of a tap land past that threshold and the viewer just
        // replayed the page the user was already on. Android's viewer has always
        // done a plain `index - 1`, and this is now the same rule.
        //
        // The first page is the one exception, and only because there is nothing
        // behind it: `next` goes negative and it restarts in place.
        if next < 0 { start(); return }
        if next >= pages.count {
            // Reaching the end is the completion, whether or not the story then restarts — and at
            // most once per showing, so a looping story does not report a completion per lap.
            if !completedReported {
                completedReported = true
                reportInteraction(
                    .storyCompleted(
                        total: pages.count,
                        timeToCompleteMs: Int(Date().timeIntervalSince(openedAt) * 1000)
                    )
                )
            }
            if restartOnCompleted { index = 0; start() } else { onDismiss() }
            return
        }
        index = next
        start()
    }

    /// Closing before the end is a dismissal; closing *at* the end is the completion already
    /// reported by `step`. Distinguishing them is what makes drop-off measurable — a viewer that
    /// always reported a dismissal would show 100% abandonment.
    private func dismissWithReport() {
        if !completedReported {
            reportInteraction(.storyPageDismissed(index: index, total: pages.count))
        }
        onDismiss()
    }

    private func pause() {
        guard !paused else { return }
        paused = true
    }

    private func resume() {
        guard paused else { return }
        paused = false
    }

    private func toggleMute() {
        muted.toggle()
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
    }

    private func start(retainingDisplayedMedia: Bool = true) {
        stop()
        progress = 0
        paused = false
        playbackGeneration += 1

        let current = page
        if !retainingDisplayedMedia || !current.thumbnailIsVideo || current.thumbnailUrl.isEmpty {
            displayedMediaKey = currentMediaKey
        }
        if current.thumbnailIsVideo, !current.thumbnailUrl.isEmpty { return }

        startAuthoredTimer()
    }

    private func startAuthoredTimer() {
        ticker?.invalidate()
        let current = page
        let mediaKey = currentMediaKey

        let interval = 1.0 / 30.0
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                guard mediaKey == currentMediaKey else { return }
                guard !paused else { return }
                progress += CGFloat(interval / max(0.1, current.duration))
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
