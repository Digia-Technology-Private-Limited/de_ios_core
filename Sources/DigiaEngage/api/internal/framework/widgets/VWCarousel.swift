import SwiftUI
import UIKit

@MainActor
final class VWCarousel: VirtualStatelessWidget<CarouselProps> {
    override func render(_ payload: RenderPayload) -> AnyView {
        guard let child = child else { return empty() }

        let repeatedItems = resolveDataSource(payload: payload)
        let pages: [AnyView]
        if let repeatedItems {
            pages = repeatedItems.enumerated().map { index, item in
                child.toWidget(payload.copyWithChainedContext(createExprContext(item, index: index)))
            }
        } else {
            pages = children?.map { $0.toWidget(payload) } ?? [child.toWidget(payload)]
        }

        guard !pages.isEmpty else { return empty() }

        return AnyView(
            DigiaCarouselView(
                pages: pages,
                width: payload.eval(props.width).map { CGFloat($0) },
                height: payload.eval(props.height).map { CGFloat($0) },
                direction: props.direction,
                aspectRatio: props.aspectRatio,
                initialPage: payload.eval(props.initialPage) ?? 0,
                autoPlay: props.autoPlay ?? false,
                autoPlayInterval: props.autoPlayInterval ?? 1600,
                animationDuration: props.animationDuration ?? 800,
                reverseScroll: props.reverseScroll ?? false,
                infiniteScroll: props.infiniteScroll ?? false,
                viewportFraction: props.viewportFraction ?? 0.8,
                enlargeCenterPage: props.enlargeCenterPage ?? false,
                enlargeFactor: props.enlargeFactor ?? 0.3,
                pageSnapping: props.pageSnapping ?? true,
                showIndicator: props.showIndicator ?? false,
                dotHeight: props.dotHeight ?? 8,
                dotWidth: props.dotWidth ?? 8,
                padEnds: props.padEnds ?? true,
                spacing: props.spacing ?? 16,
                offset: props.offset ?? 16,
                dotColor: payload.evalColor(props.dotColor) ?? .gray,
                activeDotColor: payload.evalColor(props.activeDotColor) ?? .indigo,
                indicatorEffectType: props.indicatorEffectType ?? "slide",
                onChanged: { index in
                    payload.executeAction(
                        self.props.onChanged,
                        triggerType: "onChanged",
                        scopeContext: BasicExprContext(variables: ["index": index])
                    )
                }
            )
        )
    }

    private func resolveDataSource(payload: RenderPayload) -> [Any]? {
        switch props.dataSource {
        case let .array(values):
            return values.map(\.anyValue)
        case let .string(value):
            guard ExpressionUtil.hasExpression(value),
                  let resolved = ExpressionUtil.evaluateAny(value, context: payload.scopeContext) else {
                return nil
            }
            return resolved as? [Any]
        default:
            return nil
        }
    }

    private func createExprContext(_ item: Any?, index: Int) -> any ScopeContext {
        let carouselObj: [String: Any?] = [
            "currentItem": item,
            "index": index,
        ]
        var variables = carouselObj
        if let refName {
            variables[refName] = carouselObj
        }
        return BasicExprContext(variables: variables)
    }
}

// MARK: - DigiaCarouselView
//
// iOS parity with Android's Compose HorizontalPager/VerticalPager
// (see android .../framework/widgets/VWCarousel.kt). The page surface is a
// UIScrollView-backed pager (`CarouselPager`) rather than a SwiftUI
// `DragGesture`. A UIScrollView owns an independent UIKit pan gesture
// recognizer, so — exactly like the inline story's horizontal `ScrollView`
// that already swipes correctly — it scrolls reliably even when embedded in a
// React Native (Fabric) surface, whose `RCTSurfaceTouchHandler` otherwise
// starves a SwiftUI continuous gesture. This matches the Compose pager:
// viewport-fraction peeking, enlarge-center-page scaling, infinite scroll,
// auto-play and the onChanged callback.

@MainActor
private struct DigiaCarouselView: View {
    let pages: [AnyView]
    let width: CGFloat?
    let height: CGFloat?
    let direction: String?
    let aspectRatio: Double?
    let initialPage: Int
    let autoPlay: Bool
    let autoPlayInterval: Int
    let animationDuration: Int
    let reverseScroll: Bool
    let infiniteScroll: Bool
    let viewportFraction: Double
    let enlargeCenterPage: Bool
    let enlargeFactor: Double
    let pageSnapping: Bool
    let showIndicator: Bool
    let dotHeight: Double
    let dotWidth: Double
    let padEnds: Bool
    let spacing: Double
    let offset: Double
    let dotColor: Color
    let activeDotColor: Color
    let indicatorEffectType: String
    let onChanged: (Int) -> Void

    @StateObject private var controller = CarouselController()
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let cw = width ?? geo.size.width
            let ch = resolvedHeight(containerWidth: cw)
            // Parity with Android: the configured height is the TOTAL (pager +
            // indicator). The pager shrinks to leave room for the indicator band
            // rather than the band being added on top. Band = offset + dotHeight,
            // mirroring Android's Spacer(offset) + dot-height indicator row.
            let band = showIndicator ? indicatorBand : 0
            let pagerHeight = max(ch - band, 0)

            VStack(spacing: 0) {
                CarouselPager(
                    pages: pages,
                    axisHorizontal: resolvedAxis == .horizontal,
                    viewportFraction: CGFloat(viewportFraction),
                    padEnds: padEnds,
                    infiniteScroll: infiniteScroll,
                    reverseScroll: reverseScroll,
                    enlargeCenterPage: enlargeCenterPage,
                    enlargeFactor: CGFloat(enlargeFactor),
                    initialPage: initialPage,
                    autoPlay: autoPlay,
                    autoPlayInterval: autoPlayInterval,
                    animationDuration: animationDuration,
                    pageSnapping: pageSnapping,
                    onChanged: onChanged,
                    controller: controller
                )
                .frame(width: cw, height: pagerHeight)
                .clipped()
                .onAppear { containerWidth = cw }

                if showIndicator {
                    DigiaCarouselIndicator(
                        effectType: DigiaIndicatorEffectType(rawValue: indicatorEffectType) ?? .slide,
                        pageProgress: controller.pageProgress,
                        count: pages.count,
                        dotSize: CGSize(width: dotWidth, height: dotHeight),
                        spacing: spacing,
                        offset: offset,
                        dotColor: dotColor,
                        activeDotColor: activeDotColor,
                        onDotTapped: { idx in controller.scrollToReal?(idx, true) }
                    )
                    .frame(height: CGFloat(dotHeight))
                    .padding(.top, CGFloat(offset))
                }
            }
        }
        .frame(
            width: width,
            height: totalHeight(
                containerWidth: width ?? (containerWidth > 0 ? containerWidth : fallbackContainerWidth)
            )
        )
    }

    // MARK: - Helpers

    private var fallbackContainerWidth: CGFloat {
        UIScreen.main.bounds.width
    }

    private var resolvedAxis: Axis {
        (direction ?? "horizontal").lowercased() == "vertical" ? .vertical : .horizontal
    }

    private func resolvedHeight(containerWidth: CGFloat) -> CGFloat {
        if let height { return height }
        if let aspectRatio, aspectRatio > 0 {
            return containerWidth / CGFloat(aspectRatio)
        }
        return containerWidth * 0.5
    }

    /// Vertical space reserved for the indicator below the pager, matching
    /// Android's Spacer(offset) + dot-height row.
    private var indicatorBand: CGFloat {
        CGFloat(offset) + CGFloat(dotHeight)
    }

    /// Total carousel height. Like Android, the configured height already
    /// includes the indicator band (the pager shrinks to fit it), so the total
    /// equals the configured/aspect-ratio height — no extra is added on top.
    private func totalHeight(containerWidth: CGFloat) -> CGFloat {
        resolvedHeight(containerWidth: containerWidth)
    }
}

// MARK: - CarouselController

/// Bridges the UIScrollView-backed pager and the SwiftUI indicator:
/// the pager publishes the continuous real-page progress, and the indicator
/// asks the pager to scroll when a dot is tapped.
@MainActor
private final class CarouselController: ObservableObject {
    @Published var pageProgress: Double = 0
    /// (realIndex, animated) -> scroll to that page. Set by the pager.
    var scrollToReal: ((Int, Bool) -> Void)?
}

// MARK: - CarouselPager (UIScrollView-backed)

private struct CarouselPager: UIViewRepresentable {
    let pages: [AnyView]
    let axisHorizontal: Bool
    let viewportFraction: CGFloat
    let padEnds: Bool
    let infiniteScroll: Bool
    let reverseScroll: Bool
    let enlargeCenterPage: Bool
    let enlargeFactor: CGFloat
    let initialPage: Int
    let autoPlay: Bool
    let autoPlayInterval: Int
    let animationDuration: Int
    let pageSnapping: Bool
    let onChanged: (Int) -> Void
    let controller: CarouselController

    func makeUIView(context: Context) -> CarouselContainerView {
        let view = CarouselContainerView()
        configure(view)
        return view
    }

    func updateUIView(_ view: CarouselContainerView, context: Context) {
        configure(view)
    }

    static func dismantleUIView(_ view: CarouselContainerView, coordinator: ()) {
        view.teardown()
    }

    private func configure(_ view: CarouselContainerView) {
        view.onChanged = onChanged
        view.controller = controller
        view.apply(
            axisHorizontal: axisHorizontal,
            viewportFraction: viewportFraction,
            padEnds: padEnds,
            infiniteScroll: infiniteScroll,
            reverseScroll: reverseScroll,
            enlargeCenterPage: enlargeCenterPage,
            enlargeFactor: enlargeFactor,
            initialPage: initialPage,
            autoPlay: autoPlay,
            autoPlayInterval: autoPlayInterval,
            animationDuration: animationDuration,
            pageSnapping: pageSnapping,
            pages: pages
        )
    }
}

// MARK: - CarouselContainerView

@MainActor
private final class CarouselContainerView: UIView, UIScrollViewDelegate {

    // Configuration
    private var axisHorizontal = true
    private var viewportFraction: CGFloat = 0.8
    private var padEnds = true
    private var infiniteScroll = false
    private var reverseScroll = false
    private var enlargeCenterPage = false
    private var enlargeFactor: CGFloat = 0.3
    private var initialPage = 0
    private var autoPlay = false
    private var autoPlayInterval = 1600
    private var animationDuration = 800
    private var pageSnapping = true
    private var pages: [AnyView] = []

    var onChanged: ((Int) -> Void)?
    weak var controller: CarouselController?

    // Internal state
    private let scrollView = UIScrollView()
    private var hostingControllers: [UIHostingController<AnyView>] = []
    private var parented = false
    private var didSetInitialOffset = false
    private var lastReportedReal = -1
    private var autoPlayTimer: Timer?
    private var isUserDragging = false

    // Layout-derived (updated in layoutSubviews)
    private var pageExtent: CGFloat = 0
    private var sideInset: CGFloat = 0

    private var realCount: Int { pages.count }
    private var phantom: Int { infiniteScroll && realCount > 1 ? 1 : 0 }
    private var displayCount: Int { infiniteScroll && realCount > 1 ? realCount + 2 : realCount }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.clipsToBounds = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    func apply(
        axisHorizontal: Bool,
        viewportFraction: CGFloat,
        padEnds: Bool,
        infiniteScroll: Bool,
        reverseScroll: Bool,
        enlargeCenterPage: Bool,
        enlargeFactor: CGFloat,
        initialPage: Int,
        autoPlay: Bool,
        autoPlayInterval: Int,
        animationDuration: Int,
        pageSnapping: Bool,
        pages: [AnyView]
    ) {
        let countChanged = pages.count != self.pages.count
        let structureChanged =
            axisHorizontal != self.axisHorizontal
            || infiniteScroll != self.infiniteScroll
            || reverseScroll != self.reverseScroll

        self.axisHorizontal = axisHorizontal
        self.viewportFraction = viewportFraction
        self.padEnds = padEnds
        self.infiniteScroll = infiniteScroll
        self.reverseScroll = reverseScroll
        self.enlargeCenterPage = enlargeCenterPage
        self.enlargeFactor = enlargeFactor
        self.initialPage = initialPage
        self.autoPlayInterval = autoPlayInterval
        self.animationDuration = animationDuration
        self.pageSnapping = pageSnapping
        self.autoPlay = autoPlay
        self.pages = pages

        controller?.scrollToReal = { [weak self] real, animated in
            guard let self else { return }
            self.scrollToDisplay(self.phantom + real, animated: animated)
        }

        if countChanged || structureChanged || hostingControllers.count != displayCount {
            rebuildPages()
        } else {
            // Same structure — just refresh the rendered SwiftUI content.
            for (i, hc) in hostingControllers.enumerated() {
                hc.rootView = displayPage(i)
            }
        }

        restartAutoPlayIfNeeded()
        setNeedsLayout()
    }

    func teardown() {
        autoPlayTimer?.invalidate()
        autoPlayTimer = nil
        for hc in hostingControllers {
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
        }
        hostingControllers.removeAll()
    }

    // MARK: - Page building

    private func realIndex(forDisplay display: Int) -> Int {
        guard infiniteScroll, realCount > 1 else { return min(max(display, 0), max(realCount - 1, 0)) }
        return ((display - 1) % realCount + realCount) % realCount
    }

    private func displayPage(_ display: Int) -> AnyView {
        let idx = realIndex(forDisplay: display)
        guard pages.indices.contains(idx) else { return AnyView(EmptyView()) }
        return pages[idx]
    }

    private func rebuildPages() {
        for hc in hostingControllers {
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
        }
        hostingControllers.removeAll()

        let parentVC = parented ? parentViewController() : nil
        for i in 0..<displayCount {
            let hc = UIHostingController(rootView: displayPage(i))
            hc.view.backgroundColor = .clear
            hc.view.clipsToBounds = true
            if let parentVC { parentVC.addChild(hc) }
            scrollView.addSubview(hc.view)
            if let parentVC { hc.didMove(toParent: parentVC) }
            hostingControllers.append(hc)
        }
        didSetInitialOffset = false
        lastReportedReal = -1
    }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if !parented {
                parented = true
                // Re-parent any hosting controllers created before we were in a
                // window so SwiftUI lifecycle (onAppear / .task) fires.
                if let parentVC = parentViewController() {
                    for hc in hostingControllers where hc.parent == nil {
                        parentVC.addChild(hc)
                        hc.didMove(toParent: parentVC)
                    }
                }
            }
            restartAutoPlayIfNeeded()
        } else {
            autoPlayTimer?.invalidate()
            autoPlayTimer = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cw = bounds.width
        let ch = bounds.height
        guard cw > 0, ch > 0, displayCount > 0 else { return }

        scrollView.frame = bounds

        let axisLength = axisHorizontal ? cw : ch
        pageExtent = axisLength * viewportFraction
        sideInset = padEnds ? (axisLength - pageExtent) / 2 : 0

        if axisHorizontal {
            scrollView.contentInset = UIEdgeInsets(top: 0, left: sideInset, bottom: 0, right: sideInset)
            scrollView.contentSize = CGSize(width: pageExtent * CGFloat(displayCount), height: ch)
        } else {
            scrollView.contentInset = UIEdgeInsets(top: sideInset, left: 0, bottom: sideInset, right: 0)
            scrollView.contentSize = CGSize(width: cw, height: pageExtent * CGFloat(displayCount))
        }

        for (i, hc) in hostingControllers.enumerated() {
            if axisHorizontal {
                hc.view.frame = CGRect(x: CGFloat(i) * pageExtent, y: 0, width: pageExtent, height: ch)
            } else {
                hc.view.frame = CGRect(x: 0, y: CGFloat(i) * pageExtent, width: cw, height: pageExtent)
            }
        }

        applyReverseTransform()

        if !didSetInitialOffset {
            didSetInitialOffset = true
            let start = phantom + min(max(initialPage, 0), max(realCount - 1, 0))
            scrollToDisplay(start, animated: false)
        }

        applyScaleAndProgress()
    }

    // MARK: - Reverse-scroll mirroring

    private var reverseBaseTransform: CGAffineTransform {
        guard reverseScroll else { return .identity }
        return axisHorizontal
            ? CGAffineTransform(scaleX: -1, y: 1)
            : CGAffineTransform(scaleX: 1, y: -1)
    }

    private func applyReverseTransform() {
        scrollView.transform = reverseBaseTransform
        // Counter-flip each page so its content isn't mirrored (only the scroll
        // *direction* is reversed, matching Compose reverseLayout). When
        // enlargeCenterPage is on, the per-page transform is set in
        // applyScaleAndProgress instead (it composes the flip with the scale).
        if !enlargeCenterPage {
            for hc in hostingControllers {
                hc.view.transform = reverseBaseTransform
            }
        }
    }

    // MARK: - Offset helpers

    private func offsetForDisplay(_ index: Int) -> CGPoint {
        let pos = CGFloat(index) * pageExtent - sideInset
        return axisHorizontal ? CGPoint(x: pos, y: 0) : CGPoint(x: 0, y: pos)
    }

    private var currentContinuous: CGFloat {
        guard pageExtent > 0 else { return 0 }
        let pos = axisHorizontal ? scrollView.contentOffset.x : scrollView.contentOffset.y
        return (pos + sideInset) / pageExtent
    }

    private var currentDisplayIndex: Int {
        min(max(Int(currentContinuous.rounded()), 0), max(displayCount - 1, 0))
    }

    private func scrollToDisplay(_ index: Int, animated: Bool) {
        guard pageExtent > 0 else { return }
        let clamped = min(max(index, 0), max(displayCount - 1, 0))
        let target = offsetForDisplay(clamped)
        if animated {
            let dur = max(Double(animationDuration) / 1000.0, 0.01)
            UIView.animate(withDuration: dur, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                self.scrollView.contentOffset = target
            } completion: { _ in
                self.handleSettle()
            }
        } else {
            scrollView.contentOffset = target
            applyScaleAndProgress()
        }
    }

    // MARK: - Settling / infinite wrap

    private func handleSettle() {
        if infiniteScroll, realCount > 1 {
            let disp = currentDisplayIndex
            if disp <= 0 {
                scrollToDisplay(realCount, animated: false)
            } else if disp >= displayCount - 1 {
                scrollToDisplay(1, animated: false)
            }
        }
        reportChangeIfNeeded()
    }

    private func reportChangeIfNeeded() {
        let real = realIndex(forDisplay: currentDisplayIndex)
        if real != lastReportedReal {
            lastReportedReal = real
            onChanged?(real)
        }
    }

    // MARK: - Scale + indicator progress

    private func applyScaleAndProgress() {
        let cont = currentContinuous

        if enlargeCenterPage {
            for (i, hc) in hostingControllers.enumerated() {
                let distance = abs(CGFloat(i) - cont)
                let scale = max(1 - min(distance, 1) * enlargeFactor, 0.5)
                hc.view.transform = reverseBaseTransform.scaledBy(x: scale, y: scale)
            }
        }

        let realCont: Double
        if infiniteScroll, realCount > 1 {
            let shifted = Double(cont) - Double(phantom)
            let n = Double(realCount)
            realCont = (shifted.truncatingRemainder(dividingBy: n) + n).truncatingRemainder(dividingBy: n)
        } else {
            realCont = min(max(Double(cont), 0), Double(max(realCount - 1, 0)))
        }
        controller?.pageProgress = realCont
    }

    // MARK: - Auto-play

    private func restartAutoPlayIfNeeded() {
        autoPlayTimer?.invalidate()
        autoPlayTimer = nil
        guard autoPlay, realCount > 1, window != nil else { return }
        let interval = max(Double(autoPlayInterval) / 1000.0, 0.2)
        autoPlayTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoPlayTick() }
        }
    }

    private func autoPlayTick() {
        guard autoPlay, realCount > 1, !isUserDragging, pageExtent > 0 else { return }
        let cur = currentDisplayIndex
        let next: Int
        if infiniteScroll {
            next = cur + 1
        } else if cur >= displayCount - 1 {
            next = 0
        } else {
            next = cur + 1
        }
        scrollToDisplay(next, animated: true)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        applyScaleAndProgress()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserDragging = true
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard pageSnapping, pageExtent > 0 else { return }
        let target = axisHorizontal ? targetContentOffset.pointee.x : targetContentOffset.pointee.y
        var index = ((target + sideInset) / pageExtent).rounded()
        index = min(max(index, 0), CGFloat(max(displayCount - 1, 0)))
        let snapped = index * pageExtent - sideInset
        if axisHorizontal {
            targetContentOffset.pointee.x = snapped
        } else {
            targetContentOffset.pointee.y = snapped
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        isUserDragging = false
        if !decelerate { handleSettle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        handleSettle()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        handleSettle()
    }

    // MARK: - Parent VC lookup

    private func parentViewController() -> UIViewController? {
        let reactSel = NSSelectorFromString("reactViewController")
        var view: UIView? = self
        while let v = view {
            if v.responds(to: reactSel), let raw = v.perform(reactSel)?.takeUnretainedValue() {
                if let vc = raw as? UIViewController { return vc }
            }
            view = v.superview
        }
        view = self
        while let v = view {
            var r: UIResponder? = v.next
            while let responder = r {
                if let vc = responder as? UIViewController { return vc }
                r = responder.next
            }
            view = v.superview
        }
        return nil
    }
}

// MARK: - Indicator (Flutter smooth_page_indicator parity)

private enum DigiaIndicatorEffectType: String, CaseIterable {
    case worm
    case slide
    case swap
    case expanding
    case scale
    case jumping
    case scrolling
    case circleAroundDot
}

private struct DigiaCarouselIndicator: View {
    let effectType: DigiaIndicatorEffectType
    let pageProgress: Double
    let count: Int
    let dotSize: CGSize
    let spacing: Double
    let offset: Double
    let dotColor: Color
    let activeDotColor: Color
    let onDotTapped: (Int) -> Void

    private var step: CGFloat { CGFloat(dotSize.width + spacing) }
    private var totalWidth: CGFloat { CGFloat(max(count - 1, 0)) * step + CGFloat(dotSize.width) }
    private var usesCircleDots: Bool { abs(dotSize.width - dotSize.height) < 0.5 }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { idx in
                    inactiveDot
                        .frame(width: dotSize.width, height: dotSize.height)
                        .contentShape(Rectangle())
                        .onTapGesture { onDotTapped(idx) }
                }
            }

            activeOverlay()
                .allowsHitTesting(false)
        }
        .frame(width: totalWidth, height: dotSize.height, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.22), value: pageProgress)
    }

    private var inactiveDot: some View {
        Group {
            if usesCircleDots {
                Circle().fill(dotColor)
            } else {
                Capsule().fill(dotColor)
            }
        }
    }

    @ViewBuilder
    private func activeOverlay() -> some View {
        let p = CGFloat(pageProgress)
        let i = max(0, min(Int(floor(p)), max(count - 1, 0)))
        let t = p - CGFloat(i) // 0..1

        switch effectType {
        case .slide:
            // SlideEffect: active dot translates and can overshoot by `offset`.
            let base = CGFloat(i) * step
            let travel = (t * step) + (sin(t * .pi) * CGFloat(offset))
            activeDotFill
                .frame(width: dotSize.width, height: dotSize.height)
                .offset(x: base + travel)

        case .worm:
            // WormEffect: active dot stretches between pages.
            let startX = CGFloat(i) * step
            let endX = CGFloat(min(i + 1, count - 1)) * step
            let leading = min(startX, startX + (endX - startX) * t)
            let trailing = max(startX + dotSize.width, startX + dotSize.width + (endX - startX) * t)
            Capsule()
                .fill(activeDotColor)
                .frame(width: max(trailing - leading, dotSize.width), height: dotSize.height)
                .offset(x: leading)

        case .expanding:
            // ExpandingDotsEffect: active dot widens.
            let base = p * step
            Capsule()
                .fill(activeDotColor)
                .frame(width: dotSize.width * (1.0 + 0.8 * (1.0 - abs(2 * Double(t) - 1.0))),
                       height: dotSize.height)
                .offset(x: base)

        case .scale:
            let base = p * step
            activeDotFill
                .frame(width: dotSize.width, height: dotSize.height)
                .scaleEffect(1.0 + 0.35 * (1.0 - abs(2 * Double(t) - 1.0)))
                .offset(x: base)

        case .jumping:
            let base = p * step
            activeDotFill
                .frame(width: dotSize.width, height: dotSize.height)
                .offset(x: base, y: -CGFloat(6.0 * sin(Double(t) * .pi)))

        case .swap:
            // SwapEffect: two dots swap; approximate by fading between current and next.
            let currentX = CGFloat(i) * step
            let nextX = CGFloat(min(i + 1, count - 1)) * step
            activeDotFill
                .frame(width: dotSize.width, height: dotSize.height)
                .opacity(1 - Double(t))
                .offset(x: currentX)
            activeDotFill
                .frame(width: dotSize.width, height: dotSize.height)
                .opacity(Double(t))
                .offset(x: nextX)

        case .scrolling:
            // ScrollingDotsEffect: windowed indicator; approximate by same base dots + moving active dot.
            let base = p * step
            activeDotFill
                .frame(width: dotSize.width, height: dotSize.height)
                .offset(x: base)

        case .circleAroundDot:
            let base = p * step
            ZStack {
                activeDotFill
                    .frame(width: dotSize.width, height: dotSize.height)
                Circle()
                    .stroke(activeDotColor, lineWidth: 2)
                    .frame(width: dotSize.height + dotSize.height * 1.5, height: dotSize.height + dotSize.height * 1.5)
            }
            .offset(x: base)
        }
    }

    private var activeDotFill: some View {
        Group {
            if usesCircleDots {
                Circle().fill(activeDotColor)
            } else {
                Capsule().fill(activeDotColor)
            }
        }
    }
}
