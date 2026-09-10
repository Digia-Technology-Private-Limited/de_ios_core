import SwiftUI

private let minimumBottomSheetDismissDistance: CGFloat = 120

func shouldDismissBottomSheet(dragDistance: CGFloat, sheetHeight: CGFloat) -> Bool {
    dragDistance >= max(minimumBottomSheetDismissDistance, sheetHeight * 0.25)
}

struct DigiaBottomSheetConfig {
    var cornerRadius: CGFloat = 18
    var background: Color = .white
    var scrimColor: Color = Color.black.opacity(0.4)
    var showHandle: Bool = true
    var allowBackdropDismiss: Bool = true
    var allowDragDismiss: Bool = true
    var heightCapFraction: CGFloat = 0.85
    var handleOverlaysContent: Bool = false
    var bottomPadding: CGFloat = 8
    var bottomSafeAreaMode: BottomSafeAreaMode = .none
    var bottomSafeAreaInset: CGFloat = 0
    var animateContentHeight: Bool = false
    var prioritizesDragOverScrolling: Bool = false
    var scrollsEntireSurface: Bool = false
    var entireSurfaceScrollingEnabled: Bool = true
    /// Keeps the visible card below viewport chrome such as an outside close control.
    var minimumSurfaceTop: CGFloat = 0
}

/// A bottom sheet whose card attaches flush to the screen edges (the system
/// `.sheet` reserves an unremovable bottom safe-area strip). Present it from a
/// `fullScreenCover` with a clear background and disabled cover animation.
struct DigiaBottomSheet<Content: View>: View {
    let config: DigiaBottomSheetConfig
    var scrollable: Bool = true
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    var cardBackground: AnyView? = nil
    var cardOverlay: AnyView? = nil
    /// Optional interactive chrome in viewport space, outside the card's clip.
    var viewportOverlay: ((CGRect, CGSize) -> AnyView)? = nil

    @State private var contentHeight: CGFloat = 0
    @State private var renderedSheetHeight: CGFloat = 0
    @State private var shown = false
    @State private var dragOffset: CGFloat = 0

    private let animationResponse: TimeInterval = 0.35
    private var animation: Animation { .spring(response: animationResponse, dampingFraction: 0.85) }

    var body: some View {
        GeometryReader { geo in
            let cap = min(
                geo.size.height * config.heightCapFraction,
                max(0, geo.size.height - config.minimumSurfaceTop)
            )
            let surfaceBottomInset =
                config.bottomSafeAreaMode == .insetSurface
                ? config.bottomSafeAreaInset
                : 0
            ZStack(alignment: .bottom) {
                config.scrimColor
                    .opacity(shown ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if config.allowBackdropDismiss { close() } }

                card(cap: max(0, cap - surfaceBottomInset))
                    .anchorPreference(key: NudgeCloseContainerBoundsKey.self, value: .bounds) {
                        viewportOverlay == nil ? nil : $0
                    }
                    .padding(.bottom, surfaceBottomInset)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: RenderedSheetHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                    .offset(y: shown ? max(dragOffset, 0) : geo.size.height)
                    .highPriorityGesture(
                        dragGesture,
                        including: config.prioritizesDragOverScrolling && config.allowDragDismiss
                            ? .all : .none
                    )
                    .gesture(
                        dragGesture,
                        including: config.prioritizesDragOverScrolling ? .none : .all
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .overlayPreferenceValue(NudgeCloseContainerBoundsKey.self) { anchor in
                if let anchor, let viewportOverlay {
                    viewportOverlay(geo[anchor], geo.size)
                        .opacity(shown ? 1 : 0)
                }
            }
        }
        .ignoresSafeArea(.container)
        .onPreferenceChange(SheetHeightKey.self) { height in
            if config.animateContentHeight && contentHeight > 0 {
                withAnimation(animation) { contentHeight = height }
            } else {
                contentHeight = height
            }
        }
        .onPreferenceChange(RenderedSheetHeightKey.self) { renderedSheetHeight = $0 }
        .onAppear { withAnimation(animation) { shown = true } }
    }

    private func card(cap: CGFloat) -> some View {
        let contentBottomInset =
            config.bottomSafeAreaMode == .insetContent
            ? config.bottomSafeAreaInset
            : 0
        let bottomPadding = config.bottomPadding + contentBottomInset
        let base = Group {
            if config.scrollsEntireSurface {
                entireSurfaceBody(cap: cap, bottomPadding: bottomPadding)
            } else {
                cardContents(cap: cap)
                    .padding(.bottom, bottomPadding)
            }
        }
            .frame(maxWidth: .infinity)
            .background {
                if !config.scrollsEntireSurface {
                    cardSurfaceBackground
                }
            }

        // `UnevenRoundedRectangle`'s `.rect(topLeadingRadius:topTrailingRadius:)` needs
        // iOS 16; below that, round all four corners as the closest built-in equivalent.
        return Group {
            if #available(iOS 16, *) {
                base.clipShape(
                    .rect(
                        topLeadingRadius: config.cornerRadius,
                        topTrailingRadius: config.cornerRadius)
                )
            } else {
                base.clipShape(RoundedRectangle(cornerRadius: config.cornerRadius))
            }
        }
        .overlay(alignment: .topTrailing) { cardOverlay }
        // A fully transparent background contributes no hit-testable pixels in
        // SwiftUI. Keep the whole sheet surface interactive so its drag gesture
        // wins over the backdrop tap gesture even when nothing is painted here.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cardContents(cap: CGFloat) -> some View {
        if config.handleOverlaysContent {
            ZStack(alignment: .top) {
                sheetBody(cap: cap)
                if config.showHandle { handle.padding(.top, 12) }
            }
        } else {
            VStack(spacing: 0) {
                if config.showHandle {
                    handle.padding(.top, 12).padding(.bottom, 8)
                }
                sheetBody(cap: cap)
            }
        }
    }

    private var handle: some View {
        Capsule()
            .fill(Color(hex: "#E0E0E6") ?? Color.secondary.opacity(0.35))
            .frame(width: 36, height: 4)
    }

    @ViewBuilder
    private func entireSurfaceBody(cap: CGFloat, bottomPadding: CGFloat) -> some View {
        let handleHeight: CGFloat = config.showHandle && !config.handleOverlaysContent ? 24 : 0
        let height = min(contentHeight + handleHeight + bottomPadding, cap)
        if #available(iOS 16.4, *) {
            ScrollView {
                entireSurfaceMeasuredContent(bottomPadding: bottomPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(!config.entireSurfaceScrollingEnabled)
            .frame(height: height)
        } else if #available(iOS 16, *) {
            ScrollView {
                entireSurfaceMeasuredContent(bottomPadding: bottomPadding)
            }
            .scrollDisabled(!config.entireSurfaceScrollingEnabled)
            .frame(height: height)
        } else {
            ScrollView {
                entireSurfaceMeasuredContent(bottomPadding: bottomPadding)
            }
            .frame(height: height)
        }
    }

    private func entireSurfaceMeasuredContent(bottomPadding: CGFloat) -> some View {
        entireSurfaceContent
            .padding(.bottom, bottomPadding)
            .background { cardSurfaceBackground }
    }

    @ViewBuilder
    private var cardSurfaceBackground: some View {
        if let cardBackground {
            cardBackground
        } else {
            config.background
        }
    }

    @ViewBuilder
    private var entireSurfaceContent: some View {
        if config.handleOverlaysContent {
            ZStack(alignment: .top) {
                measuredContent
                if config.showHandle { handle.padding(.top, 12) }
            }
        } else {
            VStack(spacing: 0) {
                if config.showHandle {
                    handle.padding(.top, 12).padding(.bottom, 8)
                }
                measuredContent
            }
        }
    }

    @ViewBuilder
    private func sheetBody(cap: CGFloat) -> some View {
        let height = min(contentHeight, cap)
        if scrollable {
            // `.scrollBounceBehavior(.basedOnSize)` needs iOS 16.4; below that, just
            // allow the default (always-bounces) scroll behavior.
            if #available(iOS 16.4, *) {
                ScrollView { measuredContent }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: height)
            } else {
                ScrollView { measuredContent }
                    .frame(height: height)
            }
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
                guard config.allowDragDismiss else { return }
                dragOffset =
                    value.translation.height > 0
                    ? value.translation.height
                    : value.translation.height * 0.2
            }
            .onEnded { value in
                guard config.allowDragDismiss else { return }
                if shouldDismissBottomSheet(
                    dragDistance: value.translation.height,
                    sheetHeight: renderedSheetHeight
                ) {
                    close()
                } else {
                    withAnimation(animation) { dragOffset = 0 }
                }
            }
    }

    private func close() {
        // The completion-closure overload of `withAnimation` needs iOS 17; below that,
        // fire `onDismiss()` after the spring's response time instead.
        if #available(iOS 17, *) {
            withAnimation(animation) {
                shown = false
                dragOffset = 0
            } completion: {
                onDismiss()
            }
        } else {
            withAnimation(animation) {
                shown = false
                dragOffset = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + animationResponse) {
                onDismiss()
            }
        }
    }
}

private struct SheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RenderedSheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
