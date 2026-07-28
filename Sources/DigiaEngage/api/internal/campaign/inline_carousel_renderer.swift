import SwiftUI
import UIKit
@_implementationOnly import SDWebImageSwiftUI

@MainActor
enum InlineCarouselRenderer {
    static func makeView(_ config: InlineCarouselConfig, payload: CEPTriggerPayload) -> AnyView {
        AnyView(InlineCarouselView(config: config, payload: payload))
    }
}

private struct InlineCarouselView: View {
    let config: InlineCarouselConfig
    let payload: CEPTriggerPayload
    /// Index of the currently-settled page. `nil` only before the first layout pass.
    @State private var scrollPosition: Int?
    @State private var autoPlayTimer: Timer? = nil
    /// Set just before the autoplay timer advances, so the resulting index change
    /// is attributed to autoplay (`auto = true`) rather than a manual swipe.
    @State private var autoAdvanced = false

    /// Items with a usable image, so `items[i]` (image + deepLink) stays aligned
    /// with the page index used for rendering and analytics.
    private var items: [CarouselItem] { config.items.filter { !$0.imageUrl.isEmpty } }
    /// ACarousel-style boundary clone: displayed slides are `[last] + items + [first]`
    /// (N+2 total), so "infinite" scroll needs only two extra slides instead of a
    /// multi-lap window. Landing on a clone silently re-centers onto its real
    /// counterpart (see `onChange` below) — imperceptible since the clone is
    /// pixel-identical to the item it stands in for.
    private var loopEnabled: Bool { config.infiniteScroll && items.count > 1 }
    private var pageCount: Int { loopEnabled ? items.count + 2 : items.count }
    /// Maps a display index (over `pageCount`) to a real index into `items`. Also
    /// correctly resolves the two boundary clones themselves — display index `0`
    /// (clone of the last item) and `pageCount - 1` (clone of the first item) fall
    /// out of the same modulo formula as their real counterparts.
    private func realIndex(_ displayIndex: Int) -> Int {
        guard loopEnabled else { return displayIndex }
        let n = items.count
        return (((displayIndex - 1) % n) + n) % n
    }
    private var currentIndex: Int { realIndex(scrollPosition ?? 0) }
    /// Set just before a silent (non-animated) recenter jump, so the resulting
    /// `onChange` doesn't re-fire a duplicate Step Viewed event for the same item.
    @State private var isRecentering = false

    private var variables: VariableContext {
        buildVariableContext(schemas: config.variableSchemas, cepVars: payload.variables)
    }

    var body: some View {
        // The peek-scroll/infinite-loop/autoplay mechanic below is built entirely on
        // iOS 17 view-aligned scrolling APIs (`scrollTargetLayout`, `scrollPosition`,
        // `scrollTargetBehavior(.viewAligned)`, `safeAreaPadding`); there's no small
        // native substitute, so below iOS 17 this renders nothing (unreachable in
        // practice — `Digia.initialize`/`populateCampaigns` no-op below iOS 17, so
        // no campaign trigger ever reaches this view on those OS versions).
        if items.isEmpty {
            EmptyView()
        } else if #available(iOS 17, *) {
            VStack(spacing: 0) {
                // SwiftUI's paged `TabView` can only show one full-width page at a time, so
                // `viewportFraction` (peeking neighbor slides, matching Flutter's
                // carousel_slider) is implemented with a view-aligned `ScrollView` instead —
                // each slide is sized to a fraction of the available width, and side content
                // padding centers the current slide (mirrors the Android HorizontalPager fix).
                GeometryReader { geo in
                    let fraction = CGFloat(min(max(config.viewportFraction, 0.1), 1))
                    let itemWidth = geo.size.width * fraction
                    let sidePadding = max(0, (geo.size.width - itemWidth) / 2)
                    ScrollView(.horizontal, showsIndicators: false) {
                        // A plain `HStack` (not `LazyHStack`) — with only N+2 slides now
                        // instead of a multi-lap window, eager layout is cheap, and it avoids
                        // LazyHStack's tendency to skip/garble transitions on off-screen
                        // neighbors during id-driven `scrollPosition` jumps (autoplay).
                        HStack(spacing: CGFloat(config.itemSpacing)) {
                            ForEach(0 ..< pageCount, id: \.self) { index in
                                let idx = realIndex(index)
                                WebImage(url: URL(string: items[idx].imageUrl)) {
                                    $0.resizable()
                                } placeholder: {
                                    BlurHashPlaceholderView(placeholder: items[idx].placeholder)
                                }
                                    .scaledToFill()
                                    .frame(width: itemWidth, height: CGFloat(config.height))
                                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(config.cornerRadius)))
                                    .contentShape(Rectangle())
                                    .onTapGesture { handleTap(idx) }
                                    .id(index)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    // `.safeAreaPadding` (not content `.padding`) is the pattern
                    // `.scrollTargetBehavior(.viewAligned)` expects for peeking neighbors —
                    // content padding throws off the offset math for id-driven `scrollPosition`
                    // jumps (autoplay), leaving the view under-scrolled by ~one padding's worth
                    // until a manual drag re-settles it.
                    .safeAreaPadding(.horizontal, sidePadding)
                    .scrollPosition(id: $scrollPosition)
                    .scrollTargetBehavior(.viewAligned)
                }
                .frame(maxWidth: .infinity)
                .frame(height: CGFloat(config.height))
                .onAppear {
                    if scrollPosition == nil {
                        scrollPosition = loopEnabled ? 1 : 0
                    }
                    startAutoPlay()
                }
                .onDisappear { stopAutoPlay() }
                .onChange(of: scrollPosition) { _, newValue in
                    guard let idx = newValue else { return }

                    if isRecentering {
                        isRecentering = false
                        return
                    }

                    let auto = autoAdvanced
                    autoAdvanced = false
                    // 1-based item position, matching Android's reportCarouselStepViewed.
                    SDKInstance.shared.reportCarouselStepViewed(
                        payload: payload,
                        itemIndex: realIndex(idx) + 1,
                        itemTotal: items.count,
                        auto: auto
                    )

                    // Landed on a boundary clone: silently jump to its real counterpart
                    // (no animation, no analytics) one runloop tick later — mutating
                    // `scrollPosition` synchronously within the same `onChange` that
                    // triggered it can race the in-flight scroll-view-aligned settle
                    // animation, which is what caused the old "stuck after autoplay"
                    // symptom.
                    if loopEnabled, idx == 0 || idx == pageCount - 1 {
                        let target = idx == 0 ? pageCount - 2 : 1
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

                let ind = config.indicator
                if ind.showIndicator && items.count > 1 {
                    HStack(spacing: CGFloat(ind.spacing)) {
                        ForEach(0 ..< items.count, id: \.self) { i in
                            let isActive = (currentIndex % items.count) == i
                            Circle()
                                .fill(Color(hex: isActive ? ind.activeDotColor : ind.dotColor) ?? .gray)
                                .frame(
                                    width: CGFloat(isActive ? ind.dotWidth : ind.dotWidth * 0.75),
                                    height: CGFloat(isActive ? ind.dotHeight : ind.dotHeight * 0.75)
                                )
                        }
                    }
                    .padding(.top, 8)
                }
            }
        } else {
            EmptyView()
        }
    }

    /// An item was tapped: record the click (1-based index) and open its deep link.
    private func handleTap(_ realIndex: Int) {
        let item = items[realIndex]
        let actions = item.actions
        let reportedAction = actions.first?.resolved(with: variables)
        SDKInstance.shared.reportCarouselStepClicked(
            payload: payload,
            itemIndex: realIndex + 1,
            action: reportedAction
        )
        Task {
            await SDKInstance.shared.executeActionFlow(
                actions,
                variables: variables,
                localActionExecutor: LocalActionExecutor()
            )
        }
    }

    private func startAutoPlay() {
        guard config.autoPlay, items.count > 1 else { return }
        let interval = TimeInterval(config.autoPlayInterval) / 1000
        let transitionDuration = TimeInterval(config.animationDuration) / 1000
        autoPlayTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            autoAdvanced = true
            let next = (scrollPosition ?? 0) + 1
            withAnimation(.easeInOut(duration: transitionDuration)) {
                scrollPosition = loopEnabled ? next : min(next, pageCount - 1)
            }
        }
    }

    private func stopAutoPlay() {
        autoPlayTimer?.invalidate()
        autoPlayTimer = nil
    }
}
