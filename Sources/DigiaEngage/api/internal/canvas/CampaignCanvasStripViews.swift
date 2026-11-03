internal import SDWebImageSwiftUI
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
    @Environment(\.digiaCampaignKey) private var campaignKey
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
            playback.campaignKey = campaignKey
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
    var showBackground = true

    private var scale: CGFloat { canvas.width > 0 ? width / canvas.width : 1 }

    var body: some View {
        CampaignCanvasStage(
            canvas: canvas,
            authoredCornerRadius: 0,
            isDark: isDark,
            showBackground: showBackground,
            onAction: onAction
        )
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: max(0, cornerRadius)))
    }
}

/// The scale the host draws a box at, read back from the screen.
private struct HostScaleKey: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The scale a box is drawn at, read back from its global vs local width.
/// Pure so unit tests can pin it without hosting a view. Degrades to 1
/// (the unscaled layout) for degenerate inputs rather than vanishing.
internal func unscaledHostScale(globalWidth: CGFloat, localWidth: CGFloat) -> CGFloat {
    guard localWidth > 0, globalWidth > 0 else { return 1 }
    let scale = globalWidth / localWidth
    guard scale.isFinite, scale > 0 else { return 1 }
    return scale
}

/// Hosts a UIKit-backed scroll view at its on-screen size inside a scaled canvas.
///
/// Canvas hosts draw the whole canvas through a SwiftUI `scaleEffect`. A scroll
/// view inside that scale sees every finger distance and velocity divided by the
/// scale, so on a tablet short swipes snap back and taps with a little finger
/// movement turn into drags. This measures the scale the box is actually drawn
/// at, lays `content` out that many times larger and draws it back at 1/scale,
/// so the scroll view sees no scale at all. `content` receives the scaled size
/// and the scale, and must size anything it reads in authored units with it.
/// Until the scale is measured it falls back to 1, the unscaled layout.
struct UnscaledHostBox<Content: View>: View {
    @ViewBuilder let content: (_ size: CGSize, _ scale: CGFloat) -> Content

    @State private var hostScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let scale = hostScale
            let scaled = CGSize(width: proxy.size.width * scale, height: proxy.size.height * scale)
            content(scaled, scale)
                .frame(width: scaled.width, height: scaled.height, alignment: .topLeading)
                .scaleEffect(1 / scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .background(
                    GeometryReader { measured in
                        let width = measured.size.width
                        Color.clear.preference(
                            key: HostScaleKey.self,
                            value: unscaledHostScale(
                                globalWidth: measured.frame(in: .global).width,
                                localWidth: width
                            )
                        )
                    }
                )
        }
        .onPreferenceChange(HostScaleKey.self) { measured in
            if measured > 0, abs(measured - hostScale) > 0.001 { hostScale = measured }
        }
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
    /// True while a finger is on the strip; resets itself if the touch is cancelled.
    @GestureState private var isTouching = false
    @State private var lastReportedIndex: Int?
    @State private var motion = CarouselStripMotion()
    @Environment(\.canvasInteractions) private var reportInteraction

    /// Clones on each end of a looping strip. A strip parked on a clone,
    /// before it hops to its twin, still shows its neighbours peeking in, so
    /// there must be enough clones that those neighbours exist — one clone
    /// left a blank gap beside the slide the loop had just wrapped onto.
    private var loopClones: Int {
        guard case .carousel(_, _, let viewportFraction, _, _, _, _, _, _, _, _, _, _, _, _, _) = widget,
              viewportFraction > 0, viewportFraction.isFinite else { return 1 }
        let peeking = ((1 - viewportFraction) / (2 * viewportFraction)).rounded(.up)
        return Int(min(max(peeking, 0), 8)) + 1
    }

    private func realIndex(_ displayIndex: Int, slideCount: Int, loopEnabled: Bool) -> Int {
        guard loopEnabled else { return displayIndex }
        return (((displayIndex - loopClones) % slideCount) + slideCount) % slideCount
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
            UnscaledHostBox { size, scale in
                // `size` is on-screen; authored sizes are multiplied by `scale` to match.
                let itemSpacing = itemSpacing * scale
                let cornerRadius = cornerRadius * scale
                let dotWidth = dotWidth * scale
                let dotHeight = dotHeight * scale
                let dotSpacing = dotSpacing * scale
                let indicatorGap = indicatorGap * scale
                let indicatorBottom = indicatorBottom * scale
                let indicatorHeight = showIndicator ? indicatorGap + dotHeight + indicatorBottom : 0
                let stripHeight = size.height - indicatorHeight
                // The spacing is inset around each slide, taking it out of the
                // slide's own width — the same arithmetic the dashboard runs.
                let slideWidth = size.width * viewportFraction - itemSpacing

                if stripHeight > 0 && slideWidth > 0 {
                    let loopEnabled = infiniteScroll && slides.count > 1
                    let displayCount = loopEnabled ? slides.count + 2 * loopClones : slides.count
                    let initialDisplayIndex = loopEnabled ? loopClones : 0
                    let activeIndex = realIndex(
                        scrollPosition ?? initialDisplayIndex,
                        slideCount: slides.count,
                        loopEnabled: loopEnabled
                    )

                    VStack(spacing: 0) {
                        if #available(iOS 17, *) {
                            let margin = max(0, (size.width - slideWidth) / 2)
                            let settle: @MainActor () -> Void = {
                                settleStrip(
                                    autoPlay: autoPlay,
                                    autoPlayInterval: autoPlayInterval,
                                    animationDuration: animationDuration,
                                    displayCount: displayCount,
                                    slideCount: slides.count,
                                    loopEnabled: loopEnabled
                                )
                            }
                            ScrollViewReader { proxy in
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
                            // Where the strip really is, frame by frame. The
                            // `scrollPosition` binding cannot be trusted for
                            // this: a finger landing mid-animation stops the
                            // strip between pages while the binding keeps the
                            // page it was heading to.
                            .onStripOffsetChange { offset in
                                motion.moved(
                                    to: offset,
                                    stride: slideWidth + itemSpacing,
                                    pageCount: displayCount,
                                    onRest: settle
                                )
                            }
                            .contentMargins(
                                .horizontal,
                                margin,
                                for: .scrollContent
                            )
                            .scrollPosition(id: $scrollPosition)
                            .scrollTargetBehavior(.viewAligned)
                            .frame(height: stripHeight)
                            // A finger down pauses autoplay; lifting it lets the strip
                            // settle, and only a strip at rest on a page restarts a
                            // full interval, so a tick never lands under a drag.
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 0)
                                    .updating($isTouching) { _, state, _ in state = true }
                            )
                            .onChange(of: isTouching) { _, touching in
                                motion.fingerDown = touching
                                if touching {
                                    stopAutoPlay()
                                    // Whatever the strip does next is the finger's doing.
                                    advancedAutomatically = false
                                } else {
                                    // A tap that stopped an autoplay slide mid-way moves
                                    // nothing, so no scroll update would ever say the
                                    // strip is at rest — check it now.
                                    motion.scheduleRestCheck(onRest: settle)
                                }
                            }
                            // iOS 17 cannot observe the scroll offset, so the binding
                            // is the only sign the strip moved: settle once the move
                            // has had time to finish.
                            .onChange(of: scrollPosition) { _, _ in
                                if #unavailable(iOS 18) {
                                    motion.scheduleRestCheck(
                                        after: animationDuration + CarouselStripMotion.restDelay,
                                        onRest: settle
                                    )
                                }
                            }
                            // A slide is viewed when it comes to rest. The first visible slide is
                            // reported on appear too, matching the legacy carousel.
                            .onAppear {
                                motion.proxy = proxy
                                motion.isVisible = true
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
                            .onDisappear {
                                motion.isVisible = false
                                stopAutoPlay()
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
        // Keyed by the real slide, so hopping off a loop sentinel onto its twin
        // does not report the same slide twice.
        let index = realIndex(displayIndex, slideCount: slideCount, loopEnabled: loopEnabled)
        guard lastReportedIndex != index else { return }
        lastReportedIndex = index
        reportInteraction(
            .carouselSlideViewed(
                index: index,
                total: slideCount,
                auto: auto
            )
        )
    }

    /// Runs once the strip has stopped with no finger on it: puts it squarely
    /// on a page, records the view, hops off a loop sentinel and restarts
    /// autoplay. Every step waits for rest, so none of them can fight a drag,
    /// a fling or an animation still on its way.
    @available(iOS 17, *)
    private func settleStrip(
        autoPlay: Bool,
        autoPlayInterval: TimeInterval,
        animationDuration: TimeInterval,
        displayCount: Int,
        slideCount: Int,
        loopEnabled: Bool
    ) {
        guard motion.isVisible, !motion.fingerDown, let proxy = motion.proxy else { return }
        let resting = motion.restingPage
            ?? (page: scrollPosition ?? (loopEnabled ? loopClones : 0), aligned: true)
        let restart = {
            startAutoPlay(
                autoPlay: autoPlay,
                autoPlayInterval: autoPlayInterval,
                animationDuration: animationDuration,
                displayCount: displayCount,
                slideCount: slideCount,
                loopEnabled: loopEnabled
            )
        }

        if !resting.aligned {
            // Stopped between two pages — a tap landed mid-slide. Finish the
            // move onto the nearer page. If the strip refuses to move, give
            // up after a few tries and let the next autoplay tick carry it.
            guard motion.snapAttempts < 3 else {
                motion.snapAttempts = 0
                restart()
                return
            }
            motion.snapAttempts += 1
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(resting.page, anchor: .center)
            }
            motion.scheduleRestCheck(after: 0.4) {
                settleStrip(
                    autoPlay: autoPlay,
                    autoPlayInterval: autoPlayInterval,
                    animationDuration: animationDuration,
                    displayCount: displayCount,
                    slideCount: slideCount,
                    loopEnabled: loopEnabled
                )
            }
            return
        }
        motion.snapAttempts = 0
        // `proxy.scrollTo` leaves the binding behind; the indicator reads it.
        if scrollPosition != resting.page { scrollPosition = resting.page }

        reportSlide(
            displayIndex: resting.page,
            slideCount: slideCount,
            loopEnabled: loopEnabled,
            auto: advancedAutomatically
        )
        advancedAutomatically = false

        if loopEnabled, resting.page < loopClones || resting.page >= loopClones + slideCount {
            // On a clone: jump to its real twin. The jump moves the strip,
            // which settles once more on the twin and reports nothing new.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            let twin = carouselLoopTwin(page: resting.page, slideCount: slideCount, loopClones: loopClones)
            withTransaction(transaction) {
                proxy.scrollTo(twin, anchor: .center)
                scrollPosition = twin
            }
        }
        restart()
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
                // A finger holds the strip or it is still travelling: leave it.
                // The settle that follows restarts a full interval.
                guard !motion.fingerDown, motion.isAtRest else { return }
                // Advance from where the strip really is, not from the
                // binding, which keeps the target of an interrupted slide.
                let current = motion.restingPage?.page ?? scrollPosition ?? (loopEnabled ? loopClones : 0)
                guard let next = carouselAutoPlayNextPage(
                    current: current,
                    displayCount: displayCount,
                    loopClones: loopClones,
                    loopEnabled: loopEnabled
                ) else { return }
                // Flagged before the move, so the settle it ends in knows the
                // slide arrived on a timer rather than under a finger.
                advancedAutomatically = true
                withAnimation(.easeInOut(duration: animationDuration)) {
                    if #available(iOS 18, *), let proxy = motion.proxy {
                        // Moves even when the binding already holds `next`.
                        proxy.scrollTo(next, anchor: .center)
                    } else {
                        // iOS 17 settles from the binding, so the move goes through it.
                        scrollPosition = next
                    }
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

/// The page a strip scrolled `offset` along sits nearest, and whether it is
/// squarely on it. Pages are `stride` apart; the ends are clamped so a strip
/// pulled past its first or last page still reads as that page. Degenerate
/// input reads as resting on the first page rather than trapping.
internal func carouselRestingPage(
    offset: CGFloat,
    stride: CGFloat,
    pageCount: Int
) -> (page: Int, aligned: Bool) {
    guard stride > 0, stride.isFinite, offset.isFinite, pageCount > 0 else { return (0, true) }
    let page = min(max(Int((offset / stride).rounded()), 0), pageCount - 1)
    return (page, abs(offset - CGFloat(page) * stride) < 1)
}

/// The page an autoplay tick moves a strip to from `current`, or nil when a
/// finite strip has reached its last page. A looping strip wraps off the
/// trailing clone onto the first real page: clamping there used to no-op at
/// `displayCount - 1`, parking the strip on the clone and killing autoplay.
internal func carouselAutoPlayNextPage(
    current: Int,
    displayCount: Int,
    loopClones: Int,
    loopEnabled: Bool
) -> Int? {
    if loopEnabled {
        return current >= displayCount - 1 ? loopClones : current + 1
    }
    if current >= displayCount - 1 { return nil }
    return min(current + 1, displayCount - 1)
}

/// The real page a loop clone stands in for. The strip holds `loopClones`
/// copies at each end of its `slideCount` real pages, so a leading clone's
/// twin is a lap ahead and a trailing clone's a lap behind. Only called on a
/// clone page.
internal func carouselLoopTwin(page: Int, slideCount: Int, loopClones: Int) -> Int {
    page < loopClones ? page + slideCount : page - slideCount
}

private extension View {
    /// Reports how far the strip has scrolled from its first page. iOS 17 has
    /// no way to observe a scroll offset, so there the strip is never measured
    /// and settles from changes to the page the binding holds.
    @ViewBuilder
    func onStripOffsetChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(iOS 18, *) {
            onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x + geometry.contentInsets.leading
            } action: { _, offset in
                action(offset)
            }
        } else {
            self
        }
    }
}

/// Where a carousel strip is and whether it has stopped. Kept out of SwiftUI
/// state so the per-frame scroll updates do not re-render the carousel.
@MainActor
private final class CarouselStripMotion {
    /// How long the strip must hold still to count as at rest. A drag, a fling
    /// and an animation all report every frame, so a gap this long means it
    /// has stopped.
    static let restDelay: TimeInterval = 0.12

    var proxy: ScrollViewProxy?
    var isVisible = false
    var fingerDown = false
    var snapAttempts = 0

    private var offset: CGFloat = 0
    private var stride: CGFloat = 0
    private var pageCount = 0
    private var lastMove = Date.distantPast
    private var generation = 0

    /// Nil until the strip has been measured once.
    var restingPage: (page: Int, aligned: Bool)? {
        guard stride > 0 else { return nil }
        return carouselRestingPage(offset: offset, stride: stride, pageCount: pageCount)
    }

    var isAtRest: Bool { Date().timeIntervalSince(lastMove) >= Self.restDelay }

    func moved(
        to offset: CGFloat,
        stride: CGFloat,
        pageCount: Int,
        onRest: @escaping @MainActor () -> Void
    ) {
        let changed = abs(offset - self.offset) > 0.01 || stride != self.stride
        self.offset = offset
        self.stride = stride
        self.pageCount = pageCount
        guard changed else { return }
        lastMove = Date()
        scheduleRestCheck(onRest: onRest)
    }

    /// Calls `onRest` after `delay` unless the strip moves, or another check
    /// is scheduled, first.
    func scheduleRestCheck(
        after delay: TimeInterval = restDelay,
        onRest: @escaping @MainActor () -> Void
    ) {
        generation += 1
        let expected = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.generation == expected else { return }
            onRest()
        }
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
    /// The rail's transfer token when the open came from tapping a playing thumbnail (else
    /// nil). The viewer reuses the same pool player under it — same key + same URL, so the
    /// frame stays on screen instead of flashing black.
    @State private var openHandoffKey: String?
    @Environment(\.canvasInteractions) private var reportInteraction

    static func cardWidth(railHeight: CGFloat, cardAspectRatio: CGFloat) -> CGFloat {
        railHeight * cardAspectRatio
    }

    var body: some View {
        guard case .story(
            _, let pages, let cardAspectRatio, let cardCornerRadius, let cardSpacing,
            let showRail, let thumbnailVideoPlayback, let restartOnCompleted, let startMuted, let chrome
        ) = widget, !pages.isEmpty else { return AnyView(EmptyView()) }


        return AnyView(
            // The rail is a scroll view, so it is hosted at its on-screen size;
            // see UnscaledHostBox. Scaled, it would not scroll on a tablet.
            UnscaledHostBox { size, scale in
                // Nothing renders when the rail is off: the stories are opened by
                // an `Action.showStory` elsewhere on the canvas. The widget still
                // has to be here, because it carries the stories and the chrome.
                if showRail {
                    // A card is as tall as the rail's own box, so its width
                    // follows from the authored ratio. Nothing reads a card-height
                    // property, because there isn't one.
                    let cardWidth = Self.cardWidth(railHeight: size.height, cardAspectRatio: cardAspectRatio)
                    StoryThumbnailRailView(
                        items: pages.map(canvasStoryItem),
                        mode: thumbnailVideoPlayback.asInlineStoryMode,
                        cardWidth: cardWidth,
                        cardHeight: size.height,
                        cardCornerRadius: cardCornerRadius * scale,
                        cardSpacing: cardSpacing * scale,
                        overlayOpen: openIndex != nil,
                        // The handoff token travels to the viewer: a playing thumbnail hands over
                        // its pool player, so the full-screen page starts from the frame already
                        // on screen. A still opens with no handoff and builds fresh.
                        onOpenWithHandoff: { index, handoffKey in
                            // Reported at the tap, not in the viewer's onAppear: the viewer's own onAppear
                            // reports its first page, and a child appears before its parent, so the page's
                            // Step Viewed went out ahead of the open (F13).
                            reportInteraction(.storyOpened(index: index, total: pages.count))
                            openHandoffKey = handoffKey
                            openIndex = index
                        },
                        onOpen: { index in
                            reportInteraction(.storyOpened(index: index, total: pages.count))
                            openHandoffKey = nil
                            openIndex = index
                        }
                    )
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
                    onDismiss: { openIndex = nil },
                    handoffKey: openHandoffKey,
                    safeAreaInsets: activeFloaterWindowSafeAreaInsets
                )
                .ignoresSafeArea()
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

/// The canvas entry's `StoryViewerReporter`: maps the shared viewer's completion/dismissal
/// onto canvas analytics. A class (not a struct) so the session built in the viewer's `init`
/// and the `onAppear` that hands it the environment reporter share the same instance: the
/// report closure arrives from the `canvasInteractions` environment, which does not exist yet
/// at init time, and is set before any report can fire.
///
/// Closing before the end is a dismissal; closing *at* the end is the completion the session
/// already reported. Distinguishing them is what makes drop-off measurable — a viewer that
/// always reported a dismissal would show 100% abandonment.
@MainActor
final class CanvasStoryViewerReporter: StoryViewerReporter {
    private let total: Int
    var report: ((CanvasInteraction) -> Void)?

    init(total: Int) {
        self.total = total
    }

    func onCompleted(total: Int, timeToCompleteMs: Int64) {
        report?(.storyCompleted(total: total, timeToCompleteMs: Int(timeToCompleteMs)))
    }

    func onDismissed(index: Int) {
        report?(.storyPageDismissed(index: index, total: total))
    }
}

/// Full-screen canvas story player: the story's media, the authored overlay, the
/// chrome the author arranged, tap-to-navigate, hold-to-pause and auto-advance.
///
/// The mechanics live in F's shared viewer (T10): mute and the session in
/// `StoryViewerSession` (one mute state per session, reset to the campaign default on every
/// open), the byte half of the download plan in `StoryPlanDriver`, and the media in
/// `VideoStoryPage`/`ImageStoryPage` (pool borrow under the rail's handoff key, a still below
/// every frame). This entry supplies only the canvas pieces: the stories with their authored
/// overlays, the authored chrome, and the canvas analytics mapping. Mirrors Android's
/// `CanvasStoryViewer` (T10).
@MainActor
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
    /// Physical safe-area insets supplied by the full-bleed host. Media fills
    /// the screen while authored page and chrome content stay inside these margins.
    var safeAreaInsets = EdgeInsets()
    /// The rail's transfer token when a playing thumbnail was tapped, else nil. The start page
    /// borrows its pool player under it (same key + same URL, so the frame stays on screen);
    /// every other page borrows under its own namespaced key.
    var handoffKey: String? = nil

    @StateObject private var session: StoryViewerSession
    @State private var viewerReporter: CanvasStoryViewerReporter
    /// The byte half of the download plan (players borrow through `MediaVideo`).
    @State private var planDriver = StoryPlanDriver()
    @State private var slowSource = PathSlowNetworkSource()

    @State private var displayedIndex: Int
    @State private var progress: CGFloat = 0
    @State private var videoProgress = 0.0
    @State private var lastVideoProgress = 0.0
    @State private var videoStalled = 0.0
    @State private var videoReady = false
    @State private var videoBuffering = false
    @State private var paused = false
    @State private var applicationActive = UIApplication.shared.applicationState == .active
    /// Set when the story runs to its last frame, so the teardown reports
    /// `Completed` rather than `StepDismissed`.
    @State private var completed = false
    @State private var firstFrameShown: Bool

    // ── analytics ──
    //
    // Reported from the viewer rather than the rail, because the rail cannot see any of it: a page
    // advances on a timer, a tap or a video ending, and only this view knows which page is showing.
    @Environment(\.canvasInteractions) private var reportInteraction
    @Environment(\.digiaCampaignKey) private var campaignKey
    @State private var lastReportedIndex: Int?

    init(
        pages: [CampaignCanvasStoryPage],
        chrome: CampaignCanvas,
        initialIndex: Int,
        restartOnCompleted: Bool,
        startMuted: Bool,
        isDark: Bool,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void,
        onDismiss: @escaping () -> Void,
        showsOverlays: Bool = true,
        safeAreaInsets: EdgeInsets = EdgeInsets(),
        handoffKey: String? = nil
    ) {
        self.pages = pages
        self.chrome = chrome
        self.initialIndex = initialIndex
        self.restartOnCompleted = restartOnCompleted
        self.startMuted = startMuted
        self.isDark = isDark
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.showsOverlays = showsOverlays
        self.safeAreaInsets = safeAreaInsets
        self.handoffKey = handoffKey

        let stories = pages.map(canvasStoryItem)
        let clamped = min(max(initialIndex, 0), max(stories.count - 1, 0))
        // The session (and the reporter it reports through) is first-wins state: the instance
        // built here is the one the mounted view keeps, so the relay the session holds is the
        // same one `onAppear` hands the environment reporter to.
        let reporter = CanvasStoryViewerReporter(total: stories.count)
        _viewerReporter = State(initialValue: reporter)
        // The host's dismiss through a Sendable box: the session's `onDismiss` runs on the main
        // actor, like every other report path here.
        let dismissBox = CanvasStoryCallback(run: onDismiss)
        _session = StateObject(wrappedValue: StoryViewerSession(
            stories: stories,
            startIndex: clamped,
            handoffKey: handoffKey,
            restartOnCompleted: restartOnCompleted,
            startMuted: startMuted,
            reporter: reporter,
            onDismiss: { dismissBox.run() }
        ))
        _displayedIndex = State(initialValue: clamped)
        _firstFrameShown = State(initialValue:
            stories.indices.contains(clamped) ? stories[clamped].type != .video : true)
    }

    private var page: CampaignCanvasStoryPage { pages[min(max(0, session.currentIndex), pages.count - 1)] }

    private var currentProgress: CGFloat {
        if page.thumbnailIsVideo {
            return CGFloat(min(max(videoProgress, 0), 1))
        }
        return progress
    }

    private var renderedIndices: [Int] {
        displayedIndex == session.currentIndex
            ? [session.currentIndex]
            : [displayedIndex, session.currentIndex]
    }

    var body: some View {
        GeometryReader { proxy in
            // The width the chrome and page are scaled against: the full-bleed
            // reader minus the device's unsafe margins.
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
                    Color.clear.contentShape(Rectangle()).onTapGesture { previous() }
                    Color.clear.contentShape(Rectangle()).onTapGesture { next() }
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
                // Each layer is pinned to the safe region, so neither can size the
                // stack. On a tablet the width-scaled portrait page is taller than
                // the reader; it bottom-anchors and loses its top, as the media
                // does, and the chrome stays at the top edge. Phones draw as before.
                let safeHeight = max(
                    0, proxy.size.height - safeAreaInsets.top - safeAreaInsets.bottom
                )
                // The page an action came from travels with it, so a CTA inside story 3 reports as
                // a step click on story 3 rather than as an anonymous click on the card.
                let pageAction: (CampaignCanvasActionRequest) -> Void = { request in
                    var stamped = request
                    stamped.step = CanvasStep(
                        kind: .storyPage, index: session.currentIndex, total: pages.count
                    )
                    onAction(stamped)
                }
                ScaledCanvasStage(
                    canvas: page.canvas,
                    width: contentWidth,
                    height: page.canvas.height * scale,
                    cornerRadius: 0,
                    isDark: isDark,
                    onAction: pageAction
                )
                .frame(height: safeHeight, alignment: .bottom)
                .clipped()
                .opacity(showsOverlays ? 1 : 0)
                .allowsHitTesting(showsOverlays)
                .accessibilityHidden(!showsOverlays)

                ScaledCanvasStage(
                    canvas: chrome,
                    width: contentWidth,
                    height: chrome.height * scale,
                    cornerRadius: 0,
                    isDark: isDark,
                    onAction: pageAction,
                    // Transparent by design — the page shows through, as on Flutter.
                    showBackground: false
                )
                .frame(height: safeHeight, alignment: .top)
                .clipped()
                .environment(
                    \.canvasStoryViewer,
                    CanvasStoryViewerState(
                        index: session.currentIndex,
                        pageCount: pages.count,
                        progress: currentProgress,
                        muted: session.muted
                    )
                )
                .environment(\.canvasStoryClose, CanvasStoryCallback(run: { session.dismiss() }))
                .environment(
                    \.canvasStoryToggleMute,
                    CanvasStoryCallback(run: { session.muted.toggle() })
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
                        ForEach(renderedIndices, id: \.self) { mediaIndex in
                            if session.stories.indices.contains(mediaIndex) {
                                storyMedia(
                                    story: session.stories[mediaIndex],
                                    index: mediaIndex,
                                    active: mediaIndex == session.currentIndex,
                                    muted: session.muted
                                )
                                .opacity(mediaIndex == displayedIndex ? 1 : 0)
                            }
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            // The environment reporter lands here, before any report can fire: the session is
            // built in `init`, where the environment does not exist yet.
            viewerReporter.report = reportInteraction.report
            reportPageViewed(session.currentIndex)
        }
        .onChange(of: session.currentIndex) { _ in
            reportPageViewed(session.currentIndex)
            resetTiming()
            firstFrameShown = !(currentItem?.type == .video)
            drivePlan()
        }
        // Step Viewed fires for each frame that becomes visible (including the
        // first), mirroring the media story's viewer.
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
        .onDisappear {
            planDriver.cancelAll()
            if !completed {
                session.dismiss()
            }
            // After every holder is given back, rails remount and resume.
            Task { @MainActor in
                NotificationCenter.default.post(name: .storyViewerDidClose, object: nil)
            }
        }
        .task(id: planInput) {
            drivePlan()
        }
    }

    private func reportPageViewed(_ pageIndex: Int) {
        guard lastReportedIndex != pageIndex else { return }
        lastReportedIndex = pageIndex
        reportInteraction(.storyPageViewed(index: pageIndex, total: pages.count))
    }

    private var currentItem: StoryItemConfig? {
        session.stories.indices.contains(session.currentIndex)
            ? session.stories[session.currentIndex] : nil
    }

    private var planInput: String {
        "\(session.currentIndex)-\(firstFrameShown)-\(session.replayTick)"
    }

    private func drivePlan() {
        // Snapshots: the plan driver's closures are Sendable, so they take the plain values,
        // not the MainActor-bound session.
        let urls = session.stories.map(\.url)
        let kinds = session.stories.map { $0.type == .video }
        planDriver.update(
            actions: StoryDownloadPlan.plan(
                stories: session.stories.map {
                    StoryDownloadPlan.Item(isVideo: $0.type == .video)
                },
                currentIndex: session.currentIndex,
                firstFrameShown: firstFrameShown,
                slowNetwork: slowSource.isSlow
            ),
            urlOf: { urls[$0] },
            isVideoOf: { kinds[$0] }
        )
    }

    @ViewBuilder
    private func storyMedia(story: StoryItemConfig, index: Int, active: Bool, muted: Bool) -> some View {
        // A replay remounts the current page so its video restarts from 0.
        let pageID = index == session.currentIndex
            ? "\(index)-\(session.replayTick)"
            : "\(index)"
        if story.type == .video {
            VideoStoryPage(
                item: story,
                pageKey: session.pageKey(index: index, namespace: campaignKey),
                muted: muted,
                playing: active && applicationActive && !paused,
                onReady: { _ in
                    guard index == session.currentIndex else { return }
                    videoReady = true
                    displayedIndex = index
                    firstFrameShown = true
                    drivePlan()
                },
                onProgress: {
                    guard index == session.currentIndex else { return }
                    videoProgress = $0
                },
                onEnded: {
                    guard index == session.currentIndex else { return }
                    next()
                },
                onBuffering: {
                    guard index == session.currentIndex else { return }
                    videoBuffering = $0
                },
                onFailed: {
                    // A broken full-screen item advances, as before.
                    guard index == session.currentIndex else { return }
                    next()
                }
            )
            .id(pageID)
        } else {
            ImageStoryPage(item: story) {
                guard index == session.currentIndex else { return }
                videoReady = true
                displayedIndex = index
                firstFrameShown = true
                drivePlan()
            }
            .id(pageID)
        }
    }

    private func next() {
        if session.currentIndex < session.stories.count - 1 {
            resetTiming()
            move(to: session.currentIndex + 1)
        } else {
            // The end is the completion — reported at most once per showing, then the story
            // loops or the viewer closes. Unlike the inline entry this reports even when
            // restarting: the floater's `stopOn: experienceCompleted` rule retires on it.
            completed = true
            resetTiming()
            session.advance()
            displayedIndex = session.currentIndex
        }
    }

    private func previous() {
        resetTiming()
        if session.currentIndex == 0 {
            // Re-show the first story from the top (replayTick remounts its page).
            session.goBack()
        } else {
            move(to: session.currentIndex - 1)
        }
    }

    private func move(to index: Int) {
        session.showPage(index: index)
        // Navigation must be visible on the tap that changes it. The target video already
        // draws its still until the player is ready, so switch the visible page at once.
        displayedIndex = index
    }

    private func pause() {
        guard !paused else { return }
        paused = true
    }

    private func resume() {
        guard paused else { return }
        paused = false
    }

    private func resetTiming() {
        progress = 0
        videoProgress = 0
        lastVideoProgress = 0
        videoStalled = 0
        videoBuffering = false
        videoReady = false
    }

    static func progressIncrement(
        interval: TimeInterval,
        duration: Double,
        isPaused: Bool
    ) -> CGFloat {
        guard !isPaused else { return 0 }
        return CGFloat(interval / max(0.1, duration))
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
        guard let duration = storyPageDurationSeconds(item: currentItem, defaultMs: 0) else {
            next()
            return
        }
        progress += Self.progressIncrement(interval: 0.05, duration: duration, isPaused: paused)
        if progress >= 1 { next() }
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

    static func fraction(for segment: Int, active: Int, elapsed: CGFloat) -> CGFloat {
        segment < active ? 1 : (segment == active ? min(max(elapsed, 0), 1) : 0)
    }

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
                        let fraction: CGFloat = Self.fraction(for: segment, active: active, elapsed: elapsed)
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

    static func symbol(for kind: Kind, viewer: CanvasStoryViewerState?) -> String {
        switch kind {
        case .close: "xmark"
        case .mute: (viewer?.muted ?? true) ? "speaker.slash.fill" : "speaker.wave.2.fill"
        }
    }

    static func performAction(
        kind: Kind,
        close: CanvasStoryCallback?,
        toggleMute: CanvasStoryCallback?
    ) {
        (kind == .close ? close : toggleMute)?.run()
    }

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
                .onTapGesture {
                    Self.performAction(kind: kind, close: close, toggleMute: toggleMute)
                }
            }
        }
    }

    private var symbol: String {
        Self.symbol(for: kind, viewer: viewer)
    }
}
