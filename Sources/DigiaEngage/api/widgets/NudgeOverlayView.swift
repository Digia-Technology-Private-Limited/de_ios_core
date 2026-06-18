import SwiftUI

@MainActor
struct NudgeOverlayView: View {
    @ObservedObject private var controller = SDKInstance.shared.controller

    var body: some View {
        // Center dialogs render as a custom overlay inside the host ZStack.
        // Bottom sheets use SwiftUI's native sheet, which owns the scrim,
        // drag-to-dismiss, safe-area handling and corner radius for us.
        ZStack {
            if let nudge = controller.activeNudge, !nudge.config.surface.isBottomSheet {
                NudgeDialogContainer(presentation: nudge)
                    .id(nudge.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
            }
        }
        .sheet(item: sheetBinding) { nudge in
            NudgeSheetView(presentation: nudge)
        }
    }

    /// Drives the native sheet from the controller's active nudge, but only for
    /// bottom-sheet nudges. Clearing it (swipe-down or programmatic) routes
    /// through `markNudgeDismissed()` so the Dismissed event fires and the dwell
    /// timer is consumed (symmetric with the impression on appear).
    private var sheetBinding: Binding<DigiaNudgePresentation?> {
        Binding(
            get: {
                guard let nudge = controller.activeNudge,
                    nudge.config.surface.isBottomSheet
                else { return nil }
                return nudge
            },
            set: { newValue in
                if newValue == nil { SDKInstance.shared.markNudgeDismissed() }
            }
        )
    }
}

// MARK: - Bottom sheet (native, via shared DigiaBottomSheet)

@MainActor
private struct NudgeSheetView: View {
    let presentation: DigiaNudgePresentation

    private var surface: NudgeSurface { presentation.config.surface }

    private func dismiss() { SDKInstance.shared.markNudgeDismissed() }

    var body: some View {
        DigiaBottomSheet(
            config: DigiaBottomSheetConfig(
                cornerRadius: surface.cornerRadius,
                background: surface.backgroundColor ?? .white,
                showHandle: surface.showHandle,
                // A non-draggable, non-backdrop-dismissible nudge must be closed
                // via an explicit action/close button.
                allowInteractiveDismiss: surface.draggable || surface.backdropDismissible
            )
        ) {
            renderedContent
                // Uniform surface padding on all sides (matches Flutter/Android):
                // the content column — including full-width buttons — is inset
                // equally left/right/top/bottom instead of bleeding to the edges.
                .padding(surface.padding)
        }
        .overlay(alignment: .topTrailing) {
            if surface.showCloseButton { closeButton }
        }
        // The native sheet presents this content once per nudge, so `onAppear`
        // is the impression signal (Impressed → CEP + Digia "Viewed").
        .onAppear { SDKInstance.shared.reportNudgeImpression() }
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

    /// The typed content column, rendered with the trigger variables in scope so
    /// `{{ placeholder }}` copy interpolates (mirrors Flutter's
    /// `VariableScopeProvider`).
    private var renderedContent: some View {
        NudgeColumnContent(column: presentation.config.layout, onDismiss: dismiss)
            .environment(\.digiaVariables, presentation.variables)
    }
}

// MARK: - Center dialog (custom overlay)

@MainActor
private struct NudgeDialogContainer: View {
    let presentation: DigiaNudgePresentation

    private var surface: NudgeSurface { presentation.config.surface }
    private var scrimColor: Color { surface.barrierColor ?? Color.black.opacity(0.4) }
    private var backgroundColor: Color { surface.backgroundColor ?? .white }

    private func dismiss() { SDKInstance.shared.markNudgeDismissed() }

    var body: some View {
        ZStack {
            scrimColor
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if surface.backdropDismissible { dismiss() } }

            dialogPanel
        }
        // Fires once per presentation: the `.id(nudge.id)` on the container gives
        // each nudge a fresh view identity, so `onAppear` runs once.
        .onAppear { SDKInstance.shared.reportNudgeImpression() }
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

    private var renderedContent: some View {
        NudgeColumnContent(column: presentation.config.layout, onDismiss: dismiss)
            .environment(\.digiaVariables, presentation.variables)
    }
}
