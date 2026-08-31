import SwiftUI

/// The host resolves this after fitting and positions chrome above its clipped content.
struct NudgeCloseContainerBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct CanvasNudgeCloseOverlay: View {
    let config: NudgeCloseButtonConfig
    let container: CGRect
    let viewport: CGSize
    let safeAreaInsets: UIEdgeInsets
    let isBottomSheet: Bool
    let action: () -> Void
    @ObservedObject private var theme = CampaignCanvasTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    private func color(_ token: CampaignColor?, fallback: Color) -> Color {
        guard let token else { return fallback }
        return theme.color(token, isDark: theme.isDark(colorScheme))
    }

    var body: some View {
        let safe = CGRect(
            x: safeAreaInsets.left, y: safeAreaInsets.top,
            width: max(0, viewport.width - safeAreaInsets.left - safeAreaInsets.right),
            height: max(0, viewport.height - safeAreaInsets.top - safeAreaInsets.bottom)
        )
        ZStack(alignment: .topLeading) {
            if let layout = config.placement?.layout(
                diameter: config.diameter, container: container, safe: safe,
                isBottomSheet: isBottomSheet
            ) {
                Button(action: action) {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        ZStack {
                            Circle().fill(color(config.backgroundToken, fallback: config.backgroundColor))
                            if config.iconSize > 0 {
                                Image(systemName: "xmark")
                                    .font(.system(
                                        size: min(config.iconSize, max(1, layout.circle.width - 10)),
                                        weight: .regular
                                    ))
                                    .imageScale(.small)
                                    .foregroundStyle(color(config.iconToken, fallback: config.iconColor))
                            }
                        }
                        .frame(width: layout.circle.width, height: layout.circle.height)
                        .offset(
                            x: layout.circle.minX - layout.touch.minX,
                            y: layout.circle.minY - layout.touch.minY
                        )
                    }
                    .frame(width: layout.touch.width, height: layout.touch.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .offset(x: layout.touch.minX, y: layout.touch.minY)
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }
}
