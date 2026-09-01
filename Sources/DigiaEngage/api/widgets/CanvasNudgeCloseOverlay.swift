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
                NudgeCloseButton(config: config, action: action, layout: layout)
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }
}
