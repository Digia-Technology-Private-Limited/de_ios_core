import SwiftUI

/// The inline viewer's progress strip (T8): one bar per story — seen bars full in the active color,
/// the current bar filling with `progress`, the rest in the disabled color.
/// The same pixels as `main`'s inline strip; mirrors Android `StoryProgressBar`.
@MainActor
struct StoryProgressBar: View {
    let totalItems: Int
    let currentIndex: Int
    let progress: Double
    let config: StoryIndicatorDisplayConfig

    var body: some View {
        HStack(spacing: CGFloat(config.horizontalGap)) {
            ForEach(0..<max(totalItems, 0), id: \.self) { index in
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(
                            cornerRadius: CGFloat(config.borderRadius), style: .continuous
                        )
                        .fill(backgroundColor(for: index))
                        RoundedRectangle(
                            cornerRadius: CGFloat(config.borderRadius), style: .continuous
                        )
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
