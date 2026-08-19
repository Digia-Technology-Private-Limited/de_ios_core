import Combine
import SwiftUI

@MainActor
private func performCanvasAction(
    _ request: CampaignCanvasActionRequest,
    variables: VariableContext?,
    dismiss: @escaping () -> Void
) {
    guard !request.actions.isEmpty else { return }
    let action = request.actions.first?.resolved(with: variables)
    SDKInstance.shared.emitNudgeClick(
        elementId: request.elementId,
        ctaLabel: request.label,
        actionType: action?.analyticsType,
        actionUrl: action?.analyticsURL,
        ctaRole: request.isPrimary ? "primary" : "secondary"
    )
    Task {
        await SDKInstance.shared.executeActionFlow(
            request.actions,
            variables: variables,
            localActionExecutor: LocalActionExecutor(dismiss: dismiss)
        )
    }
}

@MainActor
struct NudgeOverlayView: View {
    @ObservedObject private var controller = SDKInstance.shared.controller

    var body: some View {
        // Keep the dialog host full-bleed even while no campaign is active. A
        // scale transition on this root would also scale the scrim and briefly
        // expose safe-area bands, so only opacity is allowed at this level.
        GeometryReader { geometry in
            ZStack {
                if let nudge = controller.activeNudge, !nudge.config.surface.isBottomSheet {
                    NudgeDialogContainer(
                        presentation: nudge,
                        viewportSize: geometry.size,
                        safeAreaInsets: activeWindowSafeAreaInsets
                    )
                    .id(nudge.id)
                    .transition(.opacity)
                }

                NudgeSheetPresenter(sheet: sheetBinding)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private func nudgeScrimColor(_ surface: NudgeSurface) -> Color {
    surface.barrierColor ?? Color.black.opacity(0.4)
}

/// Isolates the UIKit full-screen-cover transaction from the inline dialog
/// layer. Disabling the cover animation here must not suppress or mutate dialog
/// transitions elsewhere in `NudgeOverlayView`.
private struct NudgeSheetPresenter: View {
    let sheet: Binding<DigiaNudgePresentation?>

    var body: some View {
        Color.clear
            .fullScreenCover(item: sheet) { nudge in
                // `.id(nudge.id)`: a direct swap between two active nudges (no
                // nil in between) must still create a fresh presentation view.
                if #available(iOS 16.4, *) {
                    NudgeSheetView(presentation: nudge)
                        .presentationBackground(.clear)
                        .id(nudge.id)
                } else {
                    NudgeSheetView(presentation: nudge).id(nudge.id)
                }
            }
            .transaction { $0.disablesAnimations = true }
    }
}

// MARK: - Bottom sheet (native, via shared DigiaBottomSheet)

@MainActor
private struct NudgeSheetView: View {
    let presentation: DigiaNudgePresentation

    private var authoredSurface: NudgeSurface { presentation.config.surface }
    private var canvas: CampaignCanvas? { presentation.config.canvas }
    private var runtimeSize: CGSize { activeWindowSize }
    private var naturalScale: CGFloat {
        canvas == nil ? 1 : runtimeSize.width / max(presentation.config.designWidth, 1)
    }
    private var surface: NudgeSurface {
        canvas == nil ? authoredSurface : authoredSurface.scaled(naturalScale)
    }
    private var hostPaintsCanvasBackground: Bool {
        canvas != nil && surface.bottomSafeAreaMode == .insetContent
    }

    private func dismiss() { SDKInstance.shared.markNudgeDismissed() }

    var body: some View {
        DigiaBottomSheet(
            config: DigiaBottomSheetConfig(
                cornerRadius: surface.cornerRadius,
                background: canvas == nil ? (surface.backgroundColor ?? .white) : .clear,
                scrimColor: nudgeScrimColor(surface),
                showHandle: surface.showHandle,
                allowBackdropDismiss: surface.backdropDismissible,
                allowDragDismiss: surface.draggable,
                heightCapFraction: canvas == nil ? 0.85 : 1,
                handleOverlaysContent: canvas != nil,
                bottomPadding: canvas == nil ? 8 : 0,
                bottomSafeAreaMode: canvas == nil ? .none : surface.bottomSafeAreaMode,
                bottomSafeAreaInset: activeWindowSafeAreaInsets.bottom
            ),
            scrollable: canvas == nil,
            onDismiss: dismiss,
            content: {
                if let canvas {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        CampaignCanvasView(
                            canvas: canvas,
                            surface: authoredSurface,
                            designWidth: presentation.config.designWidth,
                            availableSize: CGSize(
                                width: runtimeSize.width,
                                height: max(1, runtimeSize.height - 48)
                            ),
                            onAction: { request in
                                performCanvasAction(request, variables: presentation.variables, dismiss: dismiss)
                            },
                            showBackground: !hostPaintsCanvasBackground
                        )
                        Spacer(minLength: 0)
                    }
                    .environment(\.digiaVariables, presentation.variables)
                } else {
                    renderedContent.padding(surface.padding)
                }
            },
            cardBackground: hostPaintsCanvasBackground
                ? canvas.map { AnyView(CampaignCanvasBackgroundView(paint: $0.background)) }
                : nil,
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
    let viewportSize: CGSize
    let safeAreaInsets: UIEdgeInsets

    @State private var contentHeight: CGFloat = 0

    private var authoredSurface: NudgeSurface { presentation.config.surface }
    private var surface: NudgeSurface { authoredSurface }
    private var scrimColor: Color { nudgeScrimColor(surface) }
    private var backgroundColor: Color { surface.backgroundColor ?? .white }
    private func dismiss() { SDKInstance.shared.markNudgeDismissed() }

    var body: some View {
        let insets = surface.useSafeArea ? safeAreaInsets : .zero
        let width = max(1, viewportSize.width - insets.left - insets.right)
        let height = max(1, viewportSize.height - insets.top - insets.bottom)

        ZStack {
            scrimColor
                .contentShape(Rectangle())
                .onTapGesture { if surface.backdropDismissible { dismiss() } }

            Group {
                if let canvas = presentation.config.canvas {
                    let designWidth = max(presentation.config.designWidth, 1)
                    let horizontalMargin = min(
                        max(authoredSurface.minHorizontalMargin, 0),
                        max(0, (designWidth - 1) / 2)
                    )
                    let naturalScale = min(width / designWidth, 1.15)
                    let scaledSurface = authoredSurface.scaled(naturalScale)
                    canvasDialogPanel(
                        canvas: canvas,
                        surface: scaledSurface,
                        runtimeViewportWidth: width,
                        availableSize: CGSize(
                            width: width * ((designWidth - 2 * horizontalMargin) / designWidth),
                            height: max(1, height - 48)
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    dialogPanel(
                        width: width * surface.widthFraction,
                        maxHeight: height
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: width, height: height)
            .padding(
                EdgeInsets(
                    top: insets.top,
                    leading: insets.left,
                    bottom: insets.bottom,
                    trailing: insets.right
                ))
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .onPreferenceChange(DialogHeightKey.self) { contentHeight = $0 }
        // Fires once per presentation: the `.id(nudge.id)` on the container gives
        // each nudge a fresh view identity, so `onAppear` runs once.
        .onAppear { SDKInstance.shared.reportNudgeImpression() }
    }

    private func canvasDialogPanel(
        canvas: CampaignCanvas,
        surface: NudgeSurface,
        runtimeViewportWidth: CGFloat,
        availableSize: CGSize
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            CampaignCanvasView(
                canvas: canvas,
                surface: authoredSurface,
                designWidth: presentation.config.designWidth,
                runtimeViewportWidth: runtimeViewportWidth,
                availableSize: availableSize,
                onAction: { request in
                    performCanvasAction(
                        request, variables: presentation.variables, dismiss: dismiss)
                }
            )
            if surface.showCloseButton {
                NudgeCloseButton(config: surface.closeButton, action: dismiss)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: surface.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: surface.cornerRadius))
        .environment(\.digiaVariables, presentation.variables)
    }

    /// Mirrors Flutter's `_DialogFrame`: centred, width-constrained, fully
    /// rounded surface that sizes to its content up to the available area, with
    /// an optional close button.
    private func dialogPanel(width: CGFloat, maxHeight: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 0) { renderedContent }
                    .padding(surface.padding)
                    .frame(width: width)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: DialogHeightKey.self, value: geometry.size.height)
                        }
                    )
            }
            .frame(width: width, height: min(contentHeight, maxHeight))

            if surface.showCloseButton {
                NudgeCloseButton(config: surface.closeButton, action: dismiss)
            }
        }
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: surface.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: surface.cornerRadius))
        .transition(.opacity)
    }

    private var renderedContent: some View {
        NudgeColumnContent(column: presentation.config.layout, onDismiss: dismiss)
            .environment(\.digiaVariables, presentation.variables)
    }
}

@MainActor private var activeWindowSize: CGSize {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })?
        .windows.first(where: \.isKeyWindow)?
        .bounds.size ?? UIScreen.main.bounds.size
}

@MainActor private var activeWindowSafeAreaInsets: UIEdgeInsets {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })?
        .windows.first(where: \.isKeyWindow)?
        .safeAreaInsets ?? .zero
}

private struct DialogHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
