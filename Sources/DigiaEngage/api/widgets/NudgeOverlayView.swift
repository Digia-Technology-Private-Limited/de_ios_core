import SwiftUI

@MainActor
struct NudgeOverlayView: View {
    @ObservedObject private var controller = SDKInstance.shared.controller

    var body: some View {
        if let nudge = controller.activeNudge {
            NudgeContainerView(presentation: nudge)
                .id(nudge.payload.id)
                .transition(
                    nudge.config.surface.isBottomSheet
                        ? .move(edge: .bottom)
                        : .opacity.combined(with: .scale(scale: 0.95, anchor: .center))
                )
        }
    }
}

/// Carries the bottom sheet's natural content height up from a measuring
/// `GeometryReader` so the sheet can size *to its content* (capped) instead of
/// greedily filling the available height.
private struct SheetContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
private struct NudgeContainerView: View {
    let presentation: DigiaNudgePresentation
    @State private var dragOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    private var surface: NudgeSurface { presentation.config.surface }
    private var scrimColor: Color { surface.barrierColor ?? Color.black.opacity(0.4) }
    private var backgroundColor: Color { surface.backgroundColor ?? .white }

    /// Hard cap on sheet height (mirrors Android's `maxHeightRatio`); tall
    /// content scrolls within this, short content hugs its natural height.
    private var maxSheetHeight: CGFloat { UIScreen.main.bounds.height * 0.85 }

    private func dismiss() { SDKInstance.shared.controller.dismissNudge() }

    var body: some View {
        ZStack(alignment: surface.isBottomSheet ? .bottom : .center) {
            scrimColor
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if surface.backdropDismissible { dismiss() } }

            if surface.isBottomSheet {
                sheetPanel
            } else {
                dialogPanel
            }
        }
    }

    // MARK: - Panels

    /// Mirrors Flutter's `_SheetFrame`: top-rounded surface, optional drag
    /// handle, optional close button, drag-to-dismiss when `draggable`.
    private var sheetPanel: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if surface.showHandle {
                    // Drag-to-dismiss lives on the handle so it never competes
                    // with the content ScrollView's own vertical scrolling.
                    dragHandle
                        .contentShape(Rectangle())
                        .gesture(dragGesture, including: surface.draggable ? .all : .none)
                }
                // Padding lives *inside* the ScrollView (scrolls with content)
                // and the scroll view is sized to the measured content height,
                // capped — so a short nudge produces a short sheet instead of
                // expanding to the cap. Mirrors Android's content-wrapping
                // `Surface.heightIn(max =)` + scrollable column.
                ScrollView {
                    renderedContent
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: SheetContentHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                }
                .frame(height: contentHeight > 0 ? min(contentHeight, maxSheetHeight) : maxSheetHeight)
            }
            .frame(maxWidth: .infinity)
            .background(backgroundColor)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: surface.cornerRadius,
                    topTrailingRadius: surface.cornerRadius
                )
            )
            .ignoresSafeArea(.container, edges: .bottom)
            if surface.showCloseButton { closeButton }
        }
        .onPreferenceChange(SheetContentHeightKey.self) { contentHeight = $0 }
        .offset(y: max(dragOffset, 0))
    }

    /// Mirrors Flutter's `_DialogFrame`: centred, width-constrained, fully
    /// rounded surface that *sizes to its content* (unbounded height), with an
    /// optional close button.
    private var dialogPanel: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) { renderedContent }
                .padding(surface.padding)
                .frame(width: dialogWidth)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: surface.cornerRadius))

            if surface.showCloseButton { closeButton }
        }
        // Cap very tall dialogs to the screen; short content hugs naturally.
        .frame(maxHeight: UIScreen.main.bounds.height * 0.9)
        .transition(.opacity)
    }

    /// Dialog width = screen × `widthFraction`, but always inset 24pt from each
    /// screen edge (mirrors Flutter's `Dialog.insetPadding`), so a 100% width
    /// still leaves a margin instead of bleeding to the edges.
    private var dialogWidth: CGFloat {
        let screen = UIScreen.main.bounds.width
        return min(screen * surface.widthFraction, screen - 48)
    }

    // MARK: - Affordances

    private var dragHandle: some View {
        Capsule()
            .fill(Color(hex: "#E0E0E6") ?? Color.black.opacity(0.2))
            .frame(width: 36, height: 4)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "#66667A") ?? .secondary)
                .frame(width: 26, height: 26)
                .background(Color.black.opacity(0.08))
                .clipShape(Circle())
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
    }

    // MARK: - Drag-to-dismiss (bottom sheet)

    private var dragGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in dragOffset = max(value.translation.height, 0) }
            .onEnded { value in
                if value.translation.height > 120 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                }
            }
    }

    // MARK: - Nudge content

    /// The typed content column, rendered with the trigger variables in scope so
    /// `{{ placeholder }}` copy interpolates (mirrors Flutter's
    /// `VariableScopeProvider`).
    private var renderedContent: some View {
        NudgeColumnContent(column: presentation.config.layout, onDismiss: dismiss)
            .environment(\.digiaVariables, presentation.variables)
    }
}
