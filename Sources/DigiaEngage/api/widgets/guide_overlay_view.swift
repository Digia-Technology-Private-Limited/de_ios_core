import SwiftUI

// Native multi-step guide renderer (tooltip / spotlight), ported from Android's
// `GuideRenderer.kt`. Driven by GuideOrchestrator state and styled entirely from
// GuideStepWidgetConfig (no SDUI viewId), positioned against a registered anchor.
@MainActor
struct GuideOverlayView: View {
    @ObservedObject private var orchestrator = SDKInstance.shared.guideOrchestrator
    @ObservedObject private var anchors = AnchorRegistry.shared

    var body: some View {
        // Observing `anchors` re-resolves the anchor rect when an anchor
        // registers after a guide has started.
        if let state = orchestrator.state,
           let step = state.currentStep,
           let anchorRect = AnchorRegistry.shared.getRect(for: step.anchorKey) {
            GuideStepOverlay(
                step: step,
                stepIndex: state.stepIndex,
                totalSteps: state.steps.count,
                anchorRect: anchorRect,
                cornerRadius: AnchorRegistry.shared.getCornerRadius(for: step.anchorKey),
                onAdvance: { orchestrator.advance() },
                onDismiss: { SDKInstance.shared.dismissGuide() }
            )
            .environment(\.digiaVariables, state.variables)
            .id(state.stepIndex)
        }
    }
}

private struct GuideStepOverlay: View {
    let step: GuideStepModel
    let stepIndex: Int
    let totalSteps: Int
    let anchorRect: CGRect
    let cornerRadius: CGFloat
    let onAdvance: () -> Void
    let onDismiss: () -> Void

    @Environment(\.digiaVariables) private var variables
    @State private var bubbleHeight: CGFloat = 0

    private let gap: CGFloat = 14
    private let arrowH: CGFloat = 10
    private let arrowW: CGFloat = 18

    private var config: GuideStepWidgetConfig { step.widgetConfig }
    private var isSpotlight: Bool { config.overlay.visible }

    var body: some View {
        GeometryReader { geo in
            let screenH = geo.size.height
            let screenW = geo.size.width

            // Honor preferred direction ("top" → bubble below anchor); otherwise auto by space.
            let preferred = config.bubble.arrow.preferredDirection
            let spaceBelow = screenH - anchorRect.maxY
            let placeBelow: Bool = {
                switch preferred {
                case "top": return true
                case "bottom", "start", "end": return false
                default: return spaceBelow >= bubbleHeight + gap + arrowH || spaceBelow >= anchorRect.minY
                }
            }()

            let contentY = placeBelow
                ? anchorRect.maxY + gap + arrowH
                : anchorRect.minY - gap - arrowH - bubbleHeight
            let arrowCX = min(max(anchorRect.midX, arrowW / 2 + 8), screenW - arrowW / 2 - 8)
            let arrowTipY = placeBelow ? anchorRect.maxY + 2 : anchorRect.minY - 2
            let arrowBaseY = placeBelow ? anchorRect.maxY + 2 + arrowH : anchorRect.minY - 2 - arrowH

            ZStack(alignment: .topLeading) {
                // Background: spotlight scrim with cutout, or transparent tap-to-dismiss.
                if isSpotlight {
                    GuideSpotlightScrim(
                        anchorRect: anchorRect,
                        cutout: config.overlay.cutout,
                        cornerRadius: cornerRadius,
                        color: guideColor(config.overlay.color, fallback: .black),
                        alpha: config.overlay.alpha
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { if config.overlay.dismissOnTap { onDismiss() } }
                    .ignoresSafeArea()
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onDismiss() }
                        .ignoresSafeArea()
                }

                if config.bubble.arrow.visible {
                    GuideArrow(pointUp: placeBelow, color: guideColor(config.bubble.arrow.color, fallback: bubbleBackground))
                        .frame(width: arrowW, height: arrowH)
                        .position(x: arrowCX, y: (arrowTipY + arrowBaseY) / 2)
                        .allowsHitTesting(false)
                }

                bubble
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { bubbleHeight = g.size.height }
                                .onChange(of: g.size.height) { _, newValue in bubbleHeight = newValue }
                        }
                    )
                    .frame(maxWidth: CGFloat(config.bubble.maxWidthDp))
                    .position(
                        x: min(max(anchorRect.midX, CGFloat(config.bubble.maxWidthDp) / 2 + 8),
                                screenW - CGFloat(config.bubble.maxWidthDp) / 2 - 8),
                        y: contentY + bubbleHeight / 2
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        .task(id: stepIndex) {
            guard step.advanceTrigger == "auto", let delayMs = step.autoDelayMs, delayMs > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            if !Task.isCancelled { onAdvance() }
        }
    }

    private var bubbleBackground: Color { guideColor(config.bubble.backgroundColor, fallback: Color(.sRGB, red: 0.12, green: 0.25, blue: 0.69, opacity: 1)) }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = config.content.title, !title.text.isEmpty {
                Text(interpolate(title.text, variables: variables))
                    .font(.system(size: CGFloat(title.fontSize), weight: .bold))
                    .foregroundColor(guideColor(title.textColor, fallback: .white))
            }
            if let bodyText = config.content.body, !bodyText.text.isEmpty {
                Text(interpolate(bodyText.text, variables: variables))
                    .font(.system(size: CGFloat(bodyText.fontSize)))
                    .foregroundColor(guideColor(bodyText.textColor, fallback: .white.opacity(0.8)))
            }
            if config.content.stepIndicator.visible, totalSteps > 1 {
                Text("\(stepIndex + 1) / \(totalSteps)")
                    .font(.system(size: 12))
                    .foregroundColor(guideColor(config.content.stepIndicator.color, fallback: .white.opacity(0.67)))
            }
            if !config.actions.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(Array(config.actions.enumerated()), id: \.offset) { _, action in
                        Button(action: { handleAction(action) }) {
                            Text(interpolate(action.label, variables: variables))
                                .font(.system(size: 14))
                                .foregroundColor(guideColor(action.textColor, fallback: bubbleBackground))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(guideColor(action.backgroundColor, fallback: .white))
                                .clipShape(RoundedRectangle(cornerRadius: CGFloat(action.cornerRadius)))
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, CGFloat(config.bubble.paddingHorizontal))
        .padding(.vertical, CGFloat(config.bubble.paddingVertical))
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(config.bubble.cornerRadius)))
        .shadow(radius: CGFloat(config.bubble.elevation))
    }

    private func handleAction(_ action: GuideAction) {
        switch action.actionType {
        case .dismiss, .next: onAdvance()
        case .prev: break
        }
    }
}

private struct GuideArrow: View {
    let pointUp: Bool
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                if pointUp {
                    path.move(to: CGPoint(x: w / 2, y: 0))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                } else {
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: w, y: 0))
                    path.addLine(to: CGPoint(x: w / 2, y: h))
                }
                path.closeSubpath()
            }
            .fill(color)
        }
    }
}

private struct GuideSpotlightScrim: View {
    let anchorRect: CGRect
    let cutout: CutoutConfig
    let cornerRadius: CGFloat
    let color: Color
    let alpha: Double

    var body: some View {
        let pad = CGFloat(cutout.padding)
        let hole = anchorRect.insetBy(dx: -pad, dy: -pad)
        let radius: CGFloat = cutout.shape == "circle"
            ? max(hole.width, hole.height) / 2
            : CGFloat(cutout.cornerRadius)

        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(alpha)))
            context.blendMode = .clear
            let path = cutout.shape == "rect"
                ? Path(hole)
                : Path(roundedRect: hole, cornerRadius: radius)
            context.fill(path, with: .color(.black))
        }
    }
}

private func guideColor(_ hex: String, fallback: Color) -> Color {
    Color(hex: hex) ?? fallback
}
