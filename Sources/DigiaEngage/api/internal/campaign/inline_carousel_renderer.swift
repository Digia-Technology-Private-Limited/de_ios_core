import SwiftUI
import SDWebImageSwiftUI

@MainActor
enum InlineCarouselRenderer {
    static func makeView(_ config: InlineCarouselConfig) -> AnyView {
        AnyView(InlineCarouselView(config: config))
    }
}

private struct InlineCarouselView: View {
    let config: InlineCarouselConfig
    @State private var currentIndex = 0
    @State private var autoPlayTimer: Timer? = nil

    private var images: [String] { config.items.map(\.imageUrl).filter { !$0.isEmpty } }
    private var pageCount: Int { config.infiniteScroll ? 9999 : images.count }

    var body: some View {
        if images.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                TabView(selection: $currentIndex) {
                    ForEach(0 ..< pageCount, id: \.self) { index in
                        WebImage(url: URL(string: images[index % images.count]))
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: CGFloat(config.height))
                            .clipped()
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: CGFloat(config.height))
                .onAppear { startAutoPlay() }
                .onDisappear { stopAutoPlay() }

                let ind = config.indicator
                if ind.showIndicator && images.count > 1 {
                    HStack(spacing: CGFloat(ind.spacing / 2)) {
                        ForEach(0 ..< images.count, id: \.self) { i in
                            let isActive = (currentIndex % images.count) == i
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

    private func startAutoPlay() {
        guard config.autoPlay, images.count > 1 else { return }
        let interval = TimeInterval(config.autoPlayInterval) / 1000
        autoPlayTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            withAnimation { currentIndex += 1 }
        }
    }

    private func stopAutoPlay() {
        autoPlayTimer?.invalidate()
        autoPlayTimer = nil
    }
}
