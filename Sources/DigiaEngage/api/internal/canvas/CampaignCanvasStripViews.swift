internal import SDWebImageSwiftUI
import AVKit
import SwiftUI
internal import DigiaVideoEngine

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

/// A canvas story page as the story viewer's item: its media, fits, length and rail window.
/// Mapping here rather than widening that model keeps the two wire formats independent.
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
/// rail is what it draws inside its rect, and the viewer is the story layer it presents.
struct CanvasStoryRailRenderer: View {
    let widget: CampaignCanvasWidget
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void

    @State private var openIndex: Int?
    @State private var openHandover: StoryHandover?
    @State private var storyLayer = StoryLayer()
    @Environment(\.canvasInteractions) private var reportInteraction
    @Environment(\.self) private var environment

    static func cardWidth(railHeight: CGFloat, cardAspectRatio: CGFloat) -> CGFloat {
        railHeight * cardAspectRatio
    }

    var body: some View {
        guard case .story(
            _, let pages, let cardAspectRatio, let cardCornerRadius, let cardSpacing,
            let showRail, let restartOnCompleted, let startMuted, let chrome
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
                    StoryRail(
                        items: pages.map(canvasStoryItem),
                        cardWidth: cardWidth,
                        cardHeight: size.height,
                        cardCornerRadius: cardCornerRadius * scale,
                        cardSpacing: cardSpacing * scale,
                        overlayOpen: openIndex != nil
                    ) { index, handover in
                        // Reported at the tap, not in the viewer's onAppear: the viewer's own onAppear
                        // reports its first page, and a child appears before its parent, so the page's
                        // Step Viewed went out ahead of the open (F13).
                        reportInteraction(.storyOpened(index: index, total: pages.count))
                        openHandover = handover
                        openIndex = index
                        openStory(
                            at: index, handover: handover, pages: pages, chrome: chrome,
                            restartOnCompleted: restartOnCompleted, startMuted: startMuted
                        )
                    }
                }
            }
        )
    }

    private func openStory(
        at index: Int, handover: StoryHandover?, pages: [CampaignCanvasStoryPage],
        chrome: CampaignCanvas, restartOnCompleted: Bool, startMuted: Bool
    ) {
        let layer = storyLayer
        let insets = activeFloaterWindowSafeAreaInsets
        layer.present(fadeIn: true) {
            StoryLayerEnvironment(environment).apply(to:
                CanvasStoryViewer(
                    pages: pages,
                    chrome: chrome,
                    initialIndex: index,
                    restartOnCompleted: restartOnCompleted,
                    startMuted: startMuted,
                    isDark: isDark,
                    onAction: onAction,
                    onDismiss: {
                        handover?.release()
                        openHandover = nil
                        openIndex = nil
                        layer.dismiss()
                    },
                    safeAreaInsets: insets,
                    handover: handover
                )
                .ignoresSafeArea()
            )
        }
    }
}

/// The canvas story viewer (T8): a thin wrapper over the one `StoryViewer`. The canvas rail, an
/// `Action.showStory` and the story floater open it. What stays here is the canvas campaign's own
/// part, as on `main`: its pages as stories, its analytics (canvas interactions), and the
/// authored page and chrome canvases drawn over the media (`CanvasStoryPage`). Timing,
/// navigation, holding, the pool and the download plan are the shared viewer's.
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
    /// The rail card's player, when a playing card was tapped.
    var handover: StoryHandover? = nil

    @Environment(\.canvasInteractions) private var reportInteraction

    /// The one scale at which the authored story box fits `available` on both
    /// axes. A degenerate box (zero or negative side) draws at 1 rather than
    /// dividing by it.
    static func storyBoxScale(box: CGSize, available: CGSize) -> CGFloat {
        guard box.width > 0, box.height > 0 else { return 1 }
        return max(0, min(available.width / box.width, available.height / box.height))
    }

    /// A page as the viewer's story. An image page authored "fill" covers, as `main` drew it.
    static func storyItem(_ page: CampaignCanvasStoryPage) -> StoryItemConfig {
        var item = canvasStoryItem(page)
        if !page.thumbnailIsVideo, page.pageFit == "fill" { item.boxFit = .cover }
        return item
    }

    var body: some View {
        let total = pages.count
        let report = reportInteraction
        StoryViewer(entry: StoryViewerEntry(
            stories: pages.map(Self.storyItem),
            startIndex: initialIndex,
            handover: handover,
            restartOnCompleted: restartOnCompleted,
            startMuted: startMuted,
            defaultDurationMs: 5_000,
            reporter: CanvasStoryReporter(total: total, report: report),
            onDismiss: { onDismiss() },
            onPageShown: { report(.storyPageViewed(index: $0, total: total)) },
            tapLayout: .halves,
            navigationEnabled: showsOverlays,
            reportsCompletionOnLoop: true,
            dismissesOnDisappear: false
        )) { context in
            if pages.indices.contains(context.index) {
                CanvasStoryPage(
                    page: pages[context.index],
                    chrome: chrome,
                    context: context,
                    total: total,
                    isDark: isDark,
                    safeAreaInsets: safeAreaInsets,
                    showsOverlays: showsOverlays,
                    onAction: onAction
                )
            }
        }
    }
}

/// The canvas campaign's analytics for the shared viewer: canvas interactions, as on `main`.
@MainActor
private struct CanvasStoryReporter: StoryViewerReporter {
    let total: Int
    let report: CanvasInteractionReporter

    func onCompleted(total: Int, timeToCompleteMs: Int64) {
        report(.storyCompleted(total: total, timeToCompleteMs: Int(timeToCompleteMs)))
    }

    func onDismissed(index: Int) {
        report(.storyPageDismissed(index: index, total: total))
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
