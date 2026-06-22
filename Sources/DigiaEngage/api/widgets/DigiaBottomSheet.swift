import SwiftUI

struct DigiaBottomSheetConfig {
    var cornerRadius: CGFloat = 18
    var background: Color = .white
    var scrimColor: Color = Color.black.opacity(0.4)
    var showHandle: Bool = true
    var allowInteractiveDismiss: Bool = true
    var heightCapFraction: CGFloat = 0.85
}

/// A bottom sheet whose card attaches flush to the screen edges (the system
/// `.sheet` reserves an unremovable bottom safe-area strip). Present it from a
/// `fullScreenCover` with a clear background and disabled cover animation.
struct DigiaBottomSheet<Content: View>: View {
    let config: DigiaBottomSheetConfig
    var scrollable: Bool = true
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat = 0
    @State private var shown = false
    @State private var dragOffset: CGFloat = 0

    private let animation: Animation = .spring(response: 0.35, dampingFraction: 0.85)

    var body: some View {
        GeometryReader { geo in
            let cap = geo.size.height * config.heightCapFraction
            ZStack(alignment: .bottom) {
                config.scrimColor
                    .opacity(shown ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if config.allowInteractiveDismiss { close() } }

                card(cap: cap)
                    .offset(y: shown ? max(dragOffset, 0) : geo.size.height)
                    .gesture(dragGesture)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .ignoresSafeArea()
        .onPreferenceChange(SheetHeightKey.self) { contentHeight = $0 }
        .onAppear { withAnimation(animation) { shown = true } }
    }

    private func card(cap: CGFloat) -> some View {
        VStack(spacing: 0) {
            if config.showHandle {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            sheetBody(cap: cap)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(config.background)
        .clipShape(.rect(topLeadingRadius: config.cornerRadius, topTrailingRadius: config.cornerRadius))
    }

    @ViewBuilder
    private func sheetBody(cap: CGFloat) -> some View {
        let height = min(contentHeight, cap)
        if scrollable {
            ScrollView { measuredContent }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: height)
        } else {
            measuredContent.frame(height: height, alignment: .top)
        }
    }

    private var measuredContent: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: SheetHeightKey.self, value: geo.size.height)
                }
            )
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard config.allowInteractiveDismiss else { return }
                dragOffset = value.translation.height > 0
                    ? value.translation.height
                    : value.translation.height * 0.2
            }
            .onEnded { value in
                guard config.allowInteractiveDismiss else { return }
                if value.translation.height > 120 || value.predictedEndTranslation.height > 280 {
                    close()
                } else {
                    withAnimation(animation) { dragOffset = 0 }
                }
            }
    }

    private func close() {
        withAnimation(animation) {
            shown = false
            dragOffset = 0
        } completion: { onDismiss() }
    }
}

private struct SheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
