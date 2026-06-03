import SwiftUI

/// Wraps the application root and renders in-app message overlays
/// (dialogs, bottom sheets, toasts, tooltips, spotlights) above all app content via the SDUI engine.
///
/// Place this widget once, at the root of your application:
/// ```swift
/// DigiaHost {
///     DUIFactory.shared.createInitialPage()
/// }
/// ```
@MainActor
public struct DigiaHost<Content: View>: View {
    private let content: Content
    @ObservedObject private var controller = SDKInstance.shared.controller
    @ObservedObject private var surveyOrchestrator = SDKInstance.shared.surveyOrchestrator

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack {
            content
                .onAppear { SDKInstance.shared.onHostMounted() }
                .onDisappear { SDKInstance.shared.onHostUnmounted() }

            // Toast overlay (rendered natively above all navigation)
            VStack {
                Spacer()
                if let toast = controller.activeToast {
                    Text(toast.message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.bottom, 32)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: controller.activeToast != nil)

            // Survey overlay (dialog or bottom sheet, rendered above all app content).
            SurveyRenderer(orchestrator: surveyOrchestrator)

            // Anchored overlay (tooltip / spotlight)
            if let anchored = controller.activeAnchoredOverlay {
                AnchoredOverlayView(
                    state: anchored,
                    onDismiss: {
                        controller.onEvent?(.dismissed, anchored.payload)
                        controller.dismissAnchored()
                    }
                )
            }
        }
        .onChange(of: controller.activePayload) { payload in
            handlePayload(payload)
        }
    }

    private func handlePayload(_ payload: InAppPayload?) {
        guard let payload else { return }

        let command = (payload.content.command ?? payload.content.type)
            .trimmingCharacters(in: .whitespaces)
            .uppercased()

        let viewId = payload.content.viewId

        // ── Anchored overlay (tooltip / spotlight) ────────────────────────────
        if command == "SHOW_TOOLTIP" || command == "SHOW_SPOTLIGHT" {
            guard let anchorKey = payload.content.anchorKey else {
                controller.onEvent?(.dismissed, payload)
                controller.dismiss()
                return
            }

            let anchorRect: CGRect
            if let anchorView = AnchorRegistry.shared.getView(for: anchorKey) {
                // Pure-native path: view registered via DigiaAnchorViewManager.
                anchorRect = anchorView.convert(anchorView.bounds, to: nil)
            } else {
                // React Native path: coords measured in JS via measureInWindow and
                // packed into InAppPayloadContent.args by showAnchoredOverlay bridge.
                let args = payload.content.args
                guard let xJson = args["_anchorX"], case .double(let x) = xJson,
                      let yJson = args["_anchorY"], case .double(let y) = yJson,
                      let wJson = args["_anchorWidth"], case .double(let w) = wJson,
                      let hJson = args["_anchorHeight"], case .double(let h) = hJson
                else {
                    controller.onEvent?(.dismissed, payload)
                    controller.dismiss()
                    return
                }
                anchorRect = CGRect(x: x, y: y, width: w, height: h)
            }

            let cornerRadius = AnchorRegistry.shared.getCornerRadius(for: anchorKey)
            controller.onEvent?(.impressed, payload)
            controller.showAnchored(
                AnchoredOverlayState(
                    payload: payload,
                    anchorKey: anchorKey,
                    anchorRect: anchorRect,
                    command: command,
                    cornerRadius: cornerRadius
                )
            )
            controller.dismiss()
            return
        }

        // ── Dialog / BottomSheet ──────────────────────────────────────────────
        guard let viewId, !viewId.isEmpty else {
            controller.onEvent?(.dismissed, payload)
            controller.dismiss()
            return
        }

        controller.onEvent?(.impressed, payload)

        let appConfig = SDKInstance.shared.appConfigStore
        let executor = ActionExecutor()

        if command == "SHOW_BOTTOM_SHEET" || command == "BOTTOMSHEET" {
            var actionData: [String: JSONValue] = ["componentId": .string(viewId)]
            if !payload.content.args.isEmpty {
                actionData["args"] = .object(payload.content.args)
            }
            let action = ShowBottomSheetAction(disableActionIf: nil, data: actionData)
            let context = ActionProcessorContext(appConfig: appConfig, actionExecutor: executor)
            Task { @MainActor in
                try? await ShowBottomSheetProcessor().execute(action: action, context: context)
                controller.onEvent?(.dismissed, payload)
                controller.dismiss()
            }
        } else {
            var actionData: [String: JSONValue] = [
                "componentId": .string(viewId),
                "barrierDismissible": .bool(true)
            ]
            if !payload.content.args.isEmpty {
                actionData["args"] = .object(payload.content.args)
            }
            let action = ShowDialogAction(disableActionIf: nil, data: actionData)
            let context = ActionProcessorContext(appConfig: appConfig, actionExecutor: executor)
            Task { @MainActor in
                try? await ShowDialogProcessor().execute(action: action, context: context)
                controller.onEvent?(.dismissed, payload)
                controller.dismiss()
            }
        }
    }
}

// MARK: - AnchoredOverlayView

@MainActor
private struct AnchoredOverlayView: View {
    let state: AnchoredOverlayState
    let onDismiss: () -> Void

    private let gap: CGFloat = 14        // space between anchor edge and arrow tip
    private let arrowH: CGFloat = 10
    private let arrowW: CGFloat = 16
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let screenH = geo.size.height
            let screenW = geo.size.width
            let anchor = state.anchorRect
            let spaceBelow = screenH - anchor.maxY
            let placeBelow = spaceBelow >= contentHeight + gap || spaceBelow >= anchor.minY

            // Arrow tip is 2pt from the anchor edge; base touches the card top/bottom.
            // Card starts (placeBelow) or ends (above) at anchor ± gap.
            let arrowTipY: CGFloat = placeBelow
                ? anchor.maxY + 2
                : anchor.minY - 2
            let arrowBaseY: CGFloat = placeBelow
                ? anchor.maxY + 2 + arrowH
                : anchor.minY - 2 - arrowH

            let contentY = placeBelow
                ? anchor.maxY + gap
                : anchor.minY - gap - contentHeight

            // Clamp arrow center so it stays on-screen.
            let arrowCX = min(max(anchor.midX, arrowW / 2 + 8), screenW - arrowW / 2 - 8)

            ZStack {
                // Background layer: scrim for spotlight, transparent tap area for tooltip.
                if state.command == "SHOW_SPOTLIGHT" {
                    SpotlightScrimView(anchorRect: anchor, cornerRadius: state.cornerRadius)
                        .onTapGesture { onDismiss() }
                } else {
                    // Dismiss when user taps anywhere outside the content card.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onDismiss() }
                        .ignoresSafeArea()
                }

                // Triangular arrow pointing toward the anchor.
                ArrowView(
                    cx: arrowCX,
                    tipY: arrowTipY,
                    baseY: arrowBaseY,
                    width: arrowW
                )

                // SDUI content card — positioned after measuring actual height.
                VStack {
                    Spacer().frame(height: max(0, contentY))
                    AnchoredContentView(
                        viewId: state.payload.content.viewId ?? "",
                        onDismiss: onDismiss
                    )
                    .padding(.horizontal, 16)
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { contentHeight = g.size.height }
                                .onChange(of: g.size.height) { contentHeight = $0 }
                        }
                    )
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}

// MARK: - ArrowView

private struct ArrowView: View {
    let cx: CGFloat     // horizontal center of the arrow
    let tipY: CGFloat   // y of the triangle tip (closest to anchor)
    let baseY: CGFloat  // y of the triangle base (closest to card)
    let width: CGFloat

    var body: some View {
        Path { path in
            // tip is the point closest to the anchor; base is the flat edge on the card side
            path.move(to: CGPoint(x: cx, y: tipY))
            path.addLine(to: CGPoint(x: cx - width / 2, y: baseY))
            path.addLine(to: CGPoint(x: cx + width / 2, y: baseY))
            path.closeSubpath()
        }
        .fill(Color.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - SpotlightScrimView

private struct SpotlightScrimView: View {
    let anchorRect: CGRect
    var cornerRadius: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black.opacity(0.7))
            )
            var ctx = context
            ctx.blendMode = .clear
            let cutout = cornerRadius > 0
                ? Path(roundedRect: anchorRect, cornerRadius: cornerRadius)
                : Path(anchorRect)
            ctx.fill(cutout, with: .color(.black))
        }
        .ignoresSafeArea()
    }
}

// MARK: - AnchoredContentView

private struct AnchoredContentView: View {
    let viewId: String
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if !viewId.isEmpty {
                DUIFactory.shared.createComponent(viewId, args: [:])
            }
        }
        .onTapGesture { onDismiss() }
    }
}
