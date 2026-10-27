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
    var accessibilityLabel: String? = nil

    var body: some View {
        if let placement = config.placement, placement.mode == .outside, hasRoomOutside(placement) {
            outsideClose(placement)
        } else {
            resolvedClose
        }
    }

    /// Outside placement is only used when the safe area leaves room for the whole button on that edge;
    /// otherwise the inside placement keeps it on screen.
    private func hasRoomOutside(_ placement: NudgeCloseButtonPlacement) -> Bool {
        let top = isBottomSheet || placement.vertical == .top
        let available = top
            ? container.minY - safeAreaInsets.top
            : viewport.height - safeAreaInsets.bottom - container.maxY
        return available >= config.diameter
    }

    private var resolvedClose: some View {
        let safe = CGRect(
            x: safeAreaInsets.left, y: safeAreaInsets.top,
            width: max(0, viewport.width - safeAreaInsets.left - safeAreaInsets.right),
            height: max(0, viewport.height - safeAreaInsets.top - safeAreaInsets.bottom)
        )
        return ZStack(alignment: .topLeading) {
            if let layout = config.placement?.layout(
                diameter: config.diameter, container: container, safe: safe,
                isBottomSheet: isBottomSheet
            ) {
                NudgeCloseButton(config: config, action: action, layout: layout, accessibilityLabel: accessibilityLabel)
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }

    private func outsideClose(_ placement: NudgeCloseButtonPlacement) -> some View {
        let top = isBottomSheet || placement.vertical == .top
        let extent = placement.margin.top + config.diameter + placement.margin.bottom
        let originY = top ? container.minY - extent : container.maxY
        let alignment: Alignment
        switch placement.horizontal {
        case .left: alignment = top ? .topLeading : .bottomLeading
        case .center: alignment = top ? .top : .bottom
        case .right: alignment = top ? .topTrailing : .bottomTrailing
        }
        let padding = EdgeInsets(
            top: placement.margin.top,
            leading: placement.margin.left,
            bottom: placement.margin.bottom,
            trailing: placement.margin.right
        )
        let circle = CGRect(x: 0, y: 0, width: config.diameter, height: config.diameter)

        return ZStack(alignment: .topLeading) {
            ZStack(alignment: alignment) {
                NudgeCloseButton(
                    config: config,
                    action: action,
                    layout: .init(circle: circle, touch: circle),
                    accessibilityLabel: accessibilityLabel
                )
                .padding(padding)
            }
            .frame(width: container.width, height: extent, alignment: alignment)
            .offset(x: container.minX, y: originY)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }
}
