import SwiftUI
import Combine

// Native multi-step guide renderer (tooltip / spotlight), ported from Android's
// `GuideRenderer.kt`. Driven by GuideOrchestrator state and styled entirely from
// GuideStepWidgetConfig (no SDUI viewId), positioned against a registered anchor.
@MainActor
struct GuideOverlayView: View {
    @ObservedObject private var orchestrator = SDKInstance.shared.guideOrchestrator
    @StateObject private var targetAdapterStore = GuideTargetAdapterStore.shared

    var body: some View {
        if let state = orchestrator.state, let step = state.currentStep {
            switch targetAdapterStore.adapter.resolveTarget(
                GuideTargetStep(
                    spec: step.target,
                    cornerRadius: step.widgetConfig.overlay.cutout.cornerRadius
                )
            ) {
            case let .ready(anchorRect, cornerRadius, crop):
                GuideStepOverlay(
                    step: step,
                    stepIndex: state.stepIndex,
                    totalSteps: state.steps.count,
                    anchorRect: anchorRect,
                    cornerRadius: cornerRadius,
                    crop: crop,
                    onAdvance: { orchestrator.advance() },
                    onDismiss: { SDKInstance.shared.dismissGuide() }
                )
                .environment(\.digiaVariables, state.variableContext)
                .id(state.stepIndex)
            case .notReady:
                EmptyView()
            case .failed:
                EmptyView()
            }
        } else {
            EmptyView()
        }
    }
}

private struct GuideStepOverlay: View {
    let step: GuideStepModel
    let stepIndex: Int
    let totalSteps: Int
    let anchorRect: CGRect
    let cornerRadius: CGFloat
    let crop: AnchorlessCropRef?
    let onAdvance: () -> Void
    let onDismiss: () -> Void

    @Environment(\.digiaVariables) private var variables
    @State private var bubbleSize: CGSize = .zero
    @State private var cropLoaded = false

    private var config: GuideStepWidgetConfig { step.widgetConfig }
    private var isSpotlight: Bool { config.overlay.visible }

    var body: some View {
        GeometryReader { geo in
            let arrowSize = CGFloat(config.bubble.arrow.size)
            let arrowVisible = config.bubble.arrow.visible
            let gap = CGFloat(config.bubble.calloutGap) + (arrowVisible ? arrowSize : 0)
            let paddedAnchor = anchorRect.insetBy(
                dx: -CGFloat(config.overlay.cutout.padding),
                dy: -CGFloat(config.overlay.cutout.padding)
            )
            let placement = resolvedPlacement(
                preferred: config.bubble.arrow.preferredDirection,
                anchor: paddedAnchor,
                bubble: bubbleSize,
                screen: geo.size,
                gap: gap
            )
            let bubbleOrigin = calloutOrigin(
                placement: placement,
                anchor: paddedAnchor,
                bubble: bubbleSize,
                screen: geo.size,
                gap: gap
            )
            let arrowPosition = calloutArrowPosition(
                placement: placement,
                anchor: paddedAnchor,
                bubbleOrigin: bubbleOrigin,
                bubble: bubbleSize,
                cornerRadius: CGFloat(config.bubble.cornerRadius),
                arrowSize: arrowSize
            )

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

                if let crop, let url = URL(string: crop.url) {
                    DigiaCachedImageView(
                        url: url,
                        onSuccess: { _ in cropLoaded = true },
                        onFailure: { SDKInstance.shared.reportGuideRenderFailure() }
                    )
                    .scaledToFill()
                    .frame(width: anchorRect.width, height: anchorRect.height)
                    .clipShape(
                        GuideCutoutShape(
                            shape: config.overlay.cutout.shape,
                            cornerRadius: cornerRadius
                        )
                    )
                    .position(x: anchorRect.midX, y: anchorRect.midY)
                } else if crop != nil {
                    Color.clear.onAppear { SDKInstance.shared.reportGuideRenderFailure() }
                }

                if arrowVisible && bubbleSize != .zero {
                    GuideArrow(
                        direction: placement.arrowDirection,
                        color: guideColor(config.bubble.arrow.color, fallback: bubbleBackground)
                    )
                        .frame(
                            width: placement.isVertical ? arrowSize * 2 : arrowSize,
                            height: placement.isVertical ? arrowSize : arrowSize * 2
                        )
                        .position(arrowPosition)
                        .allowsHitTesting(false)
                }

                bubble
                    .frame(width: min(CGFloat(config.bubble.maxWidthDp), geo.size.width - 32))
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { bubbleSize = g.size }
                                .onChange(of: g.size) { bubbleSize = $0 }
                        }
                    )
                    .position(
                        x: bubbleOrigin.x + bubbleSize.width / 2,
                        y: bubbleOrigin.y + bubbleSize.height / 2
                    )
                    .opacity(bubbleSize == .zero ? 0 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .opacity(crop == nil || cropLoaded ? 1 : 0)
        }
        .onAppear {
            if crop == nil { SDKInstance.shared.reportGuideShown() }
        }
        .onChange(of: cropLoaded) { loaded in
            if loaded { SDKInstance.shared.reportGuideShown() }
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
                Text(interpolate(title.text, context: variables))
                    .font(
                        Font(SDKInstance.shared.font.resolve(
                            size: Double(title.fontSize),
                            weight: title.fontWeight,
                            italic: false
                        ))
                    )
                    .foregroundColor(guideColor(title.textColor, fallback: .white))
            }
            if let bodyText = config.content.body, !bodyText.text.isEmpty {
                Text(interpolate(bodyText.text, context: variables))
                    .font(
                        Font(SDKInstance.shared.font.resolve(
                            size: Double(bodyText.fontSize),
                            weight: bodyText.fontWeight,
                            italic: false
                        ))
                    )
                    .foregroundColor(guideColor(bodyText.textColor, fallback: .white.opacity(0.8)))
            }
            if config.content.stepIndicator.visible, totalSteps > 1 {
                Text("\(stepIndex + 1) / \(totalSteps)")
                    .font(
                        Font(SDKInstance.shared.font.resolve(
                            size: 12,
                            weight: config.content.stepIndicator.fontWeight,
                            italic: false
                        ))
                    )
                    .foregroundColor(guideColor(config.content.stepIndicator.color, fallback: .white.opacity(0.67)))
            }
            if !config.actions.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(Array(config.actions.enumerated()), id: \.offset) { _, action in
                        actionButton(action)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, CGFloat(config.bubble.paddingHorizontal))
        .padding(.vertical, CGFloat(config.bubble.paddingVertical))
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(config.bubble.cornerRadius)))
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(config.bubble.cornerRadius))
                .stroke(
                    guideColor(config.bubble.borderColor, fallback: .clear),
                    lineWidth: CGFloat(config.bubble.borderWidth)
                )
        )
        .shadow(radius: CGFloat(config.bubble.elevation))
    }

    private func actionButton(_ action: GuideAction) -> some View {
        let filled = action.style == "fill" || action.style == "filled" || action.style == "elevated"
        let outlined = action.style == "outline"
        let accent = guideColor(
            action.backgroundColor,
            fallback: Color(red: 73 / 255, green: 69 / 255, blue: 1)
        )
        let shape = RoundedRectangle(cornerRadius: CGFloat(action.cornerRadius))
        return Button(action: { handleAction(action) }) {
            Text(interpolate(action.label, context: variables))
                .font(
                    Font(SDKInstance.shared.font.resolve(
                        size: action.fontSize,
                        weight: action.fontWeight,
                        italic: false
                    ))
                )
                .foregroundColor(filled ? guideColor(action.textColor, fallback: .white) : accent)
                .padding(
                    EdgeInsets(
                        top: CGFloat(action.padding.top),
                        leading: CGFloat(action.padding.left),
                        bottom: CGFloat(action.padding.bottom),
                        trailing: CGFloat(action.padding.right)
                    )
                )
                .background(filled ? accent : .clear)
                .clipShape(shape)
                .overlay(shape.stroke(outlined ? accent : .clear, lineWidth: outlined ? 1.5 : 0))
                .shadow(radius: action.style == "elevated" ? 3 : 0, y: action.style == "elevated" ? 2 : 0)
        }
        .padding(
            EdgeInsets(
                top: CGFloat(action.margin.top),
                leading: CGFloat(action.margin.left),
                bottom: CGFloat(action.margin.bottom),
                trailing: CGFloat(action.margin.right)
            )
        )
    }

    private func handleAction(_ action: GuideAction) {
        guard SDKInstance.shared.guideOrchestrator.state != nil else { return }
        let reportedAction = action.actions.first?.resolved(with: variables)
        SDKInstance.shared.reportGuideStepClicked(
            actionType: reportedAction?.analyticsType,
            actionUrl: reportedAction?.analyticsURL,
            ctaLabel: interpolate(action.label, context: variables)
        )
        Task {
            await SDKInstance.shared.executeActionFlow(
                action.actions,
                variables: variables,
                localActionExecutor: LocalActionExecutor(
                    dismiss: onDismiss,
                    next: onAdvance,
                    previous: { SDKInstance.shared.previousGuide() }
                )
            )
        }
    }
}

private enum CalloutPlacement {
    case above
    case below
    case left
    case right

    var isVertical: Bool { self == .above || self == .below }

    var arrowDirection: GuideArrowDirection {
        switch self {
        case .above: return .down
        case .below: return .up
        case .left: return .right
        case .right: return .left
        }
    }
}

private enum GuideArrowDirection {
    case up
    case down
    case left
    case right
}

private func resolvedPlacement(
    preferred: String,
    anchor: CGRect,
    bubble: CGSize,
    screen: CGSize,
    gap: CGFloat
) -> CalloutPlacement {
    let requested: CalloutPlacement = switch preferred {
    case "above", "bottom": .above
    case "below", "top": .below
    case "left", "start": .left
    case "right", "end": .right
    default: .below
    }
    guard bubble != .zero else { return requested }
    let margin: CGFloat = 16
    let fitsAbove = anchor.minY - gap - bubble.height >= margin
    let fitsBelow = anchor.maxY + gap + bubble.height <= screen.height - margin
    let fitsLeft = anchor.minX - gap - bubble.width >= margin
    let fitsRight = anchor.maxX + gap + bubble.width <= screen.width - margin
    switch requested {
    case .above: return fitsAbove || !fitsBelow ? .above : .below
    case .below: return fitsBelow || !fitsAbove ? .below : .above
    case .left: return fitsLeft || !fitsRight ? .left : .right
    case .right: return fitsRight || !fitsLeft ? .right : .left
    }
}

private func calloutOrigin(
    placement: CalloutPlacement,
    anchor: CGRect,
    bubble: CGSize,
    screen: CGSize,
    gap: CGFloat
) -> CGPoint {
    let margin: CGFloat = 16
    let raw: CGPoint = switch placement {
    case .above:
        CGPoint(x: anchor.midX - bubble.width / 2, y: anchor.minY - gap - bubble.height)
    case .below:
        CGPoint(x: anchor.midX - bubble.width / 2, y: anchor.maxY + gap)
    case .left:
        CGPoint(x: anchor.minX - gap - bubble.width, y: anchor.midY - bubble.height / 2)
    case .right:
        CGPoint(x: anchor.maxX + gap, y: anchor.midY - bubble.height / 2)
    }
    return CGPoint(
        x: min(max(raw.x, margin), max(margin, screen.width - margin - bubble.width)),
        y: min(max(raw.y, margin), max(margin, screen.height - margin - bubble.height))
    )
}

private func calloutArrowPosition(
    placement: CalloutPlacement,
    anchor: CGRect,
    bubbleOrigin: CGPoint,
    bubble: CGSize,
    cornerRadius: CGFloat,
    arrowSize: CGFloat
) -> CGPoint {
    let inset = cornerRadius + arrowSize + 2
    if placement.isVertical {
        let x = min(
            max(anchor.midX, bubbleOrigin.x + inset),
            bubbleOrigin.x + bubble.width - inset
        )
        let y = placement == .below
            ? bubbleOrigin.y - arrowSize / 2
            : bubbleOrigin.y + bubble.height + arrowSize / 2
        return CGPoint(x: x, y: y)
    }
    let y = min(
        max(anchor.midY, bubbleOrigin.y + inset),
        bubbleOrigin.y + bubble.height - inset
    )
    let x = placement == .right
        ? bubbleOrigin.x - arrowSize / 2
        : bubbleOrigin.x + bubble.width + arrowSize / 2
    return CGPoint(x: x, y: y)
}

private struct GuideArrow: View {
    let direction: GuideArrowDirection
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                switch direction {
                case .up:
                    path.move(to: CGPoint(x: w / 2, y: 0))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                case .down:
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: w, y: 0))
                    path.addLine(to: CGPoint(x: w / 2, y: h))
                case .left:
                    path.move(to: CGPoint(x: 0, y: h / 2))
                    path.addLine(to: CGPoint(x: w, y: 0))
                    path.addLine(to: CGPoint(x: w, y: h))
                case .right:
                    path.move(to: CGPoint(x: w, y: h / 2))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: 0, y: 0))
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
        let shape = GuideCutoutShape(shape: cutout.shape, cornerRadius: cornerRadius)

        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(alpha)))
            context.blendMode = .clear
            let path = shape.path(in: hole)
            context.fill(path, with: .color(.black))
            if cutout.glowWidth > 0 {
                context.blendMode = .normal
                context.addFilter(
                    .shadow(
                        color: guideColor(cutout.glowColor, fallback: .clear),
                        radius: 1.5
                    )
                )
                context.stroke(
                    path,
                    with: .color(guideColor(cutout.glowColor, fallback: .clear)),
                    lineWidth: CGFloat(cutout.glowWidth)
                )
            }
        }
    }
}

private struct GuideCutoutShape: Shape {
    let shape: String
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        switch shape {
        case "circle":
            let side = max(rect.width, rect.height)
            return Path(ellipseIn: CGRect(
                x: rect.midX - side / 2,
                y: rect.midY - side / 2,
                width: side,
                height: side
            ))
        case "pill":
            return Path(roundedRect: rect, cornerRadius: rect.height / 2)
        case "rect" where cornerRadius == 0:
            return Path(rect)
        default:
            return Path(roundedRect: rect, cornerRadius: cornerRadius)
        }
    }
}

private func guideColor(_ hex: String, fallback: Color) -> Color {
    Color(hex: hex) ?? fallback
}
