import SwiftUI

@MainActor
struct NudgeOverlayView: View {
    @ObservedObject private var controller = SDKInstance.shared.controller

    var body: some View {
        // The centered dialog stays an in-host overlay; the bottom sheet is
        // presented through SwiftUI's native `.sheet`, which slides up, dims
        // the host, owns its drag-to-dismiss, and — crucially — paints its
        // background (and corner radius) all the way down through the home-
        // indicator safe area for free. No manual safe-area maths.
        ZStack {
            if let nudge = controller.activeNudge, !nudge.config.surface.isBottomSheet {
                NudgeDialogView(presentation: nudge)
                    .id(nudge.payload.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
            }
        }
        .sheet(item: bottomSheetItem) { item in
            NudgeSheetContent(presentation: item.presentation)
        }
    }

    /// Drives the native sheet off the active nudge. Setting it back to `nil`
    /// (native swipe / tap-outside dismissal) routes through the controller so
    /// the `.dismissed` event still fires.
    private var bottomSheetItem: Binding<BottomSheetItem?> {
        Binding(
            get: {
                guard let nudge = controller.activeNudge,
                      nudge.config.surface.isBottomSheet else { return nil }
                return BottomSheetItem(presentation: nudge)
            },
            set: { newValue in
                if newValue == nil { SDKInstance.shared.controller.dismissNudge() }
            }
        )
    }
}

/// Identifiable wrapper so `.sheet(item:)` keeps rendering the captured
/// presentation through the dismissal animation even after `activeNudge`
/// has already been cleared on the controller.
private struct BottomSheetItem: Identifiable, Equatable {
    let presentation: DigiaNudgePresentation
    var id: String { presentation.payload.id }
}

// MARK: - Bottom sheet (native)

@MainActor
private struct NudgeSheetContent: View {
    let presentation: DigiaNudgePresentation
    @State private var contentHeight: CGFloat = 0

    private var surface: NudgeSurface { presentation.config.surface }
    private var backgroundColor: Color { surface.backgroundColor ?? .white }

    private func dismiss() { SDKInstance.shared.controller.dismissNudge() }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                nudgeRenderedContent(presentation)
                    .padding(surface.padding)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        contentHeight = $0
                    }
            }
            .scrollBounceBehavior(.basedOnSize)

            if surface.showCloseButton { nudgeCloseButton(action: dismiss) }
        }
        // Size the sheet to its content; an over-tall sheet is clamped by the
        // system and the inner ScrollView takes over.
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight)] : [.medium])
        .presentationDragIndicator(surface.showHandle ? .visible : .hidden)
        .presentationCornerRadius(surface.cornerRadius)
        // Paints the whole sheet — including the bottom safe area — in the
        // surface colour, so there's no bare gap under the content.
        .presentationBackground(backgroundColor)
        .interactiveDismissDisabled(!surface.backdropDismissible && !surface.draggable)
    }
}

// MARK: - Dialog (centered overlay)

@MainActor
private struct NudgeDialogView: View {
    let presentation: DigiaNudgePresentation

    private var surface: NudgeSurface { presentation.config.surface }
    private var scrimColor: Color { surface.barrierColor ?? Color.black.opacity(0.4) }
    private var backgroundColor: Color { surface.backgroundColor ?? .white }

    private func dismiss() { SDKInstance.shared.controller.dismissNudge() }

    var body: some View {
        ZStack(alignment: .center) {
            scrimColor
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if surface.backdropDismissible { dismiss() } }

            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) { nudgeRenderedContent(presentation) }
                    .padding(surface.padding)
                    .frame(width: dialogWidth)
                    .background(backgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: surface.cornerRadius))

                if surface.showCloseButton { nudgeCloseButton(action: dismiss) }
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.9)
            .transition(.opacity)
        }
    }

    private var dialogWidth: CGFloat {
        let screen = UIScreen.main.bounds.width
        return min(screen * surface.widthFraction, screen - 48)
    }
}

// MARK: - Shared affordances

@MainActor
private func nudgeCloseButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
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

@MainActor
private func nudgeRenderedContent(_ presentation: DigiaNudgePresentation) -> some View {
    NudgeColumnContent(
        column: presentation.config.layout,
        onDismiss: { SDKInstance.shared.controller.dismissNudge() }
    )
    .environment(\.digiaVariables, presentation.variables)
}
