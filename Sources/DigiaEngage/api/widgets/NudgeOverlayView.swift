import SwiftUI
import Combine

@MainActor
struct NudgeOverlayView: View {
    @ObservedObject private var controller = SDKInstance.shared.controller

    var body: some View {
        // Center dialogs and bottom sheets both render as custom overlays. The
        // bottom sheet uses a full-screen cover with a clear background and
        // disabled cover animation, so `DigiaBottomSheet` can attach its card
        // flush to the screen edges (the native `.sheet` reserves a bottom
        // safe-area strip that can't be removed) and drive its own spring.
        ZStack {
            if let nudge = controller.activeNudge, !nudge.config.surface.isBottomSheet {
                NudgeDialogContainer(presentation: nudge)
                    .id(nudge.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
            }
        }
        .fullScreenCover(item: sheetBinding) { nudge in
            // `.id(nudge.id)`: a direct swap between two active nudges (no nil in
            // between) doesn't re-trigger `.onAppear` without a forced identity
            // change — SwiftUI otherwise updates the same view in place.
            //
            // `.presentationBackground` needs iOS 16.4; below that, the cover's
            // (opaque) default background is used as-is.
            if #available(iOS 16.4, *) {
                NudgeSheetView(presentation: nudge).presentationBackground(.clear).id(nudge.id)
            } else {
                NudgeSheetView(presentation: nudge).id(nudge.id)
            }
        }
        .transaction { $0.disablesAnimations = true }
    }

    /// Drives the cover from the controller's active nudge, but only for
    /// bottom-sheet nudges. Clearing it routes through `markNudgeDismissed()` so
    /// the Dismissed event fires and the dwell timer is consumed (symmetric with
    /// the impression on appear).
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
                scrimColor: surface.barrierColor ?? Color.black.opacity(0.4),
                showHandle: surface.showHandle,
                allowInteractiveDismiss: surface.draggable || surface.backdropDismissible
            ),
            onDismiss: dismiss,
            content: {
                renderedContent
                    .padding(surface.padding)
            },
            cardOverlay: surface.showCloseButton
                ? AnyView(NudgeCloseButton(config: surface.closeButton, action: dismiss))
                : nil
        )
        // The cover presents this content once per nudge, so `onAppear` is the
        // impression signal (Impressed → CEP + Digia "Viewed").
        .onAppear { SDKInstance.shared.reportNudgeImpression() }
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

            if surface.showCloseButton {
                NudgeCloseButton(config: surface.closeButton, action: dismiss)
            }
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

    private var renderedContent: some View {
        NudgeColumnContent(column: presentation.config.layout, onDismiss: dismiss)
            .environment(\.digiaVariables, presentation.variables)
    }
}

/// Fixed cross visual with an inward-expanding, platform-minimum hit target.
private struct NudgeCloseButton: View {
    let config: NudgeCloseButtonConfig
    let action: () -> Void

    private var touchSize: CGFloat { max(config.diameter, 44) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Color.clear
                ZStack {
                    Circle().fill(config.backgroundColor)
                    if config.iconSize > 0 {
                        Image(systemName: "xmark")
                            .font(.system(size: config.iconSize, weight: .regular))
                            .imageScale(.small)
                            .foregroundStyle(config.iconColor)
                    }
                }
                .frame(width: config.diameter, height: config.diameter)
            }
            .frame(width: touchSize, height: touchSize, alignment: .topTrailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .padding(.top, config.marginTop)
        .padding(.trailing, config.marginRight)
    }
}
