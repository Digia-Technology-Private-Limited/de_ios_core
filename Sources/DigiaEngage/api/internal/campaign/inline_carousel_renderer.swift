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
    @State private var currentIndex = 0
    @State private var autoPlayTimer: Timer? = nil
    /// Set just before the autoplay timer advances, so the resulting index change
    /// is attributed to autoplay (`auto = true`) rather than a manual swipe.
    @State private var autoAdvanced = false

    /// Items with a usable image, so `items[i]` (image + deepLink) stays aligned
    /// with the page index used for rendering and analytics.
    private var items: [CarouselItem] { config.items.filter { !$0.imageUrl.isEmpty } }
    private var pageCount: Int { config.infiniteScroll ? 9999 : items.count }

    private var variables: VariableContext {
        buildVariableContext(schemas: config.variableSchemas, cepVars: payload.variables)
    }

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                TabView(selection: $currentIndex) {
                    ForEach(0 ..< pageCount, id: \.self) { index in
                        let realIndex = index % items.count
                        WebImage(url: URL(string: items[realIndex].imageUrl))
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: CGFloat(config.height))
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { handleTap(realIndex) }
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: CGFloat(config.height))
                .onAppear { startAutoPlay() }
                .onDisappear { stopAutoPlay() }
                .onChange(of: currentIndex) { _, idx in
                    let auto = autoAdvanced
                    autoAdvanced = false
                    // 1-based item position, matching Android's reportCarouselStepViewed.
                    SDKInstance.shared.reportCarouselStepViewed(
                        payload: payload,
                        itemIndex: (idx % items.count) + 1,
                        itemTotal: items.count,
                        auto: auto
                    )
                }

                let ind = config.indicator
                if ind.showIndicator && items.count > 1 {
                    HStack(spacing: CGFloat(ind.spacing / 2)) {
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
        }
    }

    /// An item was tapped: record the click (1-based index) and open its deep link.
    private func handleTap(_ realIndex: Int) {
        let item = items[realIndex]
        let link = item.deepLink.map { interpolate($0, context: variables) }
        SDKInstance.shared.reportCarouselStepClicked(
            payload: payload,
            itemIndex: realIndex + 1,
            actionUrl: link
        )
        if let link, let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }

    private func startAutoPlay() {
        guard config.autoPlay, items.count > 1 else { return }
        let interval = TimeInterval(config.autoPlayInterval) / 1000
        autoPlayTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            autoAdvanced = true
            withAnimation { currentIndex += 1 }
        }
    }

    private func stopAutoPlay() {
        autoPlayTimer?.invalidate()
        autoPlayTimer = nil
    }
}
