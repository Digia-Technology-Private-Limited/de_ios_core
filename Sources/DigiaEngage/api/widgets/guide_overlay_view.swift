import SwiftUI
import Combine
import UIKit

// Native multi-step guide renderer (tooltip / spotlight), ported from Android's
// `GuideRenderer.kt`. Driven by GuideOrchestrator state and styled entirely from
// GuideStepWidgetConfig (no SDUI viewId), positioned against a registered anchor.
@MainActor
struct GuideOverlayView: View {
    @ObservedObject private var orchestrator = SDKInstance.shared.guideOrchestrator
    @ObservedObject private var anchors = AnchorRegistry.shared

    var body: some View {
        if let state = orchestrator.state, let step = state.currentStep {
            switch resolve(state, cornerRadius: step.widgetConfig.overlay.cutout.cornerRadius) {
            case let .ready(anchorRect, cornerRadius, imageURL):
                GuideStepOverlay(
                    step: step,
                    stepIndex: state.stepIndex,
                    totalSteps: state.steps.count,
                    designWidth: state.campaign.guideConfig?.designWidth
                        ?? defaultCampaignCanvasDesignWidth,
                    anchorRect: anchorRect,
                    cornerRadius: cornerRadius,
                    imageURL: imageURL,
                    nextImageURL: state.steps.indices.contains(state.stepIndex + 1)
                        ? state.steps[state.stepIndex + 1].target.anchorlessTarget?.imageURL
                        : nil,
                    onAdvance: imageURL == nil
                        ? { orchestrator.advance() }
                        : { SDKInstance.shared.advanceGuide() },
                    onDismiss: { SDKInstance.shared.dismissGuide() }
                )
                .environment(\.digiaVariables, state.variableContext)
                .id(state.stepIndex)
            case .notReady:
                EmptyView()
            case let .failed(failure):
                Color.clear.task(id: "\(state.campaign.id):\(state.stepIndex):\(failure.rawValue)") {
                    SDKInstance.shared.reportGuideRenderFailure(failure)
                }
            }
        } else {
            EmptyView()
        }
    }

    private func resolve(
        _ state: ActiveGuideState,
        cornerRadius: CGFloat
    ) -> GuideResolvedTarget {
        guard let current = state.currentStep else { return .failed(.invalidTarget) }
        if state.campaign.guideConfig?.isAnchorless == true {
            guard let window = keyWindow else { return .failed(.invalidGeometry) }
            for step in state.steps {
                guard let target = step.target.anchorlessTarget else {
                    return .failed(.invalidTarget)
                }
                if case let .failure(failure) = target.resolve(
                    currentPageKey: SDKInstance.shared.currentScreenForAnchorless,
                    window: window
                ) {
                    return .failed(failure)
                }
            }
        }
        return resolve(current.target, cornerRadius: cornerRadius)
    }

    private func resolve(_ target: GuideTarget, cornerRadius: CGFloat) -> GuideResolvedTarget {
        switch target {
        case let .registeredAnchor(anchorKey):
            guard let rect = anchors.getRect(for: anchorKey) else { return .notReady }
            return .ready(
                rect,
                anchors.getCornerRadius(for: anchorKey),
                nil
            )
        case let .anchorless(target):
            guard let window = keyWindow else { return .failed(.invalidGeometry) }
            switch target.resolve(
                currentPageKey: SDKInstance.shared.currentScreenForAnchorless,
                window: window
            ) {
            case let .success(rect):
                return .ready(rect, cornerRadius, target.imageURL)
            case let .failure(failure):
                return .failed(failure)
            }
        }
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private enum GuideResolvedTarget {
    case ready(CGRect, CGFloat, URL?)
    case notReady
    case failed(AnchorlessFailure)
}

private struct GuideStepOverlay: View {
    let step: GuideStepModel
    let stepIndex: Int
    let totalSteps: Int
    let designWidth: CGFloat
    let anchorRect: CGRect
    let cornerRadius: CGFloat
    let imageURL: URL?
    let nextImageURL: URL?
    let onAdvance: () -> Void
    let onDismiss: () -> Void

    @Environment(\.digiaVariables) private var variables
    @State private var bubbleSize: CGSize = .zero
    @State private var targetImage: UIImage?
    @State private var imageLoaded = false
    @State private var delayElapsedForStep: Int?

    private var config: GuideStepWidgetConfig { step.widgetConfig }
    private var isSpotlight: Bool { config.overlay.visible }
    private var isPresentationReady: Bool {
        guard imageURL != nil else { return true }
        let delayElapsed = (step.delayInMs ?? 0) <= 0 || delayElapsedForStep == stepIndex
        return imageLoaded && delayElapsed
    }

    var body: some View {
        GeometryReader { geo in
            let isAnchorless = imageURL != nil
            let arrowSize = isAnchorless ? CGFloat(config.bubble.arrow.size) : 10
            let arrowVisible = config.bubble.arrow.visible
            let gap = isAnchorless
                ? CGFloat(config.bubble.calloutGap) + (arrowVisible ? arrowSize : 0)
                : 24
            let paddedAnchor = anchorRect.insetBy(
                dx: -CGFloat(config.overlay.cutout.padding),
                dy: -CGFloat(config.overlay.cutout.padding)
            )
            let placement = isAnchorless
                ? resolvedPlacement(
                    preferred: config.bubble.arrow.preferredDirection,
                    anchor: paddedAnchor,
                    bubble: bubbleSize,
                    screen: geo.size,
                    gap: gap
                )
                : resolvedClassicPlacement(
                    preferred: config.bubble.arrow.preferredDirection,
                    anchor: anchorRect,
                    bubble: bubbleSize,
                    screen: geo.size
                )
            let placementAnchor = isAnchorless ? paddedAnchor : anchorRect
            let bubbleOrigin = isAnchorless
                ? calloutOrigin(
                    placement: placement,
                    anchor: placementAnchor,
                    bubble: bubbleSize,
                    screen: geo.size,
                    gap: gap
                )
                : classicBubbleOrigin(
                    placement: placement,
                    anchor: anchorRect,
                    bubble: bubbleSize,
                    screenWidth: geo.size.width,
                    maxWidth: CGFloat(config.bubble.maxWidthDp)
                )
            let arrowPosition = isAnchorless
                ? calloutArrowPosition(
                    placement: placement,
                    anchor: paddedAnchor,
                    bubbleOrigin: bubbleOrigin,
                    bubble: bubbleSize,
                    cornerRadius: CGFloat(config.bubble.cornerRadius),
                    arrowSize: arrowSize
                )
                : classicArrowPosition(
                    placement: placement,
                    anchor: anchorRect,
                    screenWidth: geo.size.width
                )

            ZStack(alignment: .topLeading) {
                // Background: spotlight scrim with cutout, or transparent tap-to-dismiss.
                if isSpotlight {
                    GuideSpotlightScrim(
                        anchorRect: anchorRect,
                        cutout: config.overlay.cutout,
                        cornerRadius: cornerRadius,
                        isAnchorless: isAnchorless,
                        color: guideColor(config.overlay.color, fallback: .black),
                        alpha: config.overlay.alpha
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard config.overlay.dismissOnTap else { return }
                        if imageURL == nil { onDismiss() } else { onAdvance() }
                    }
                    .ignoresSafeArea()
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onDismiss() }
                        .ignoresSafeArea()
                }

                if let targetImage {
                    Image(uiImage: targetImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: anchorRect.width, height: anchorRect.height)
                    .clipShape(
                        GuideCutoutShape(
                            shape: config.overlay.cutout.shape,
                            cornerRadius: cornerRadius
                        )
                    )
                    .position(x: anchorRect.midX, y: anchorRect.midY)
                }

                positionedBubble(
                    viewportSize: geo.size,
                    origin: bubbleOrigin,
                    isAnchorless: isAnchorless
                )

                if arrowVisible && bubbleSize != .zero {
                    GuideArrow(
                        direction: placement.arrowDirection,
                        color: guideColor(config.bubble.arrow.color, fallback: bubbleBackground)
                    )
                        .frame(
                            width: isAnchorless
                                ? (placement.isVertical ? arrowSize * 2 : arrowSize)
                                : 18,
                            height: isAnchorless
                                ? (placement.isVertical ? arrowSize : arrowSize * 2)
                                : 10
                        )
                        .position(arrowPosition)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .opacity(isPresentationReady ? 1 : 0)
            .allowsHitTesting(isPresentationReady)
        }
        .onChange(of: isPresentationReady) { ready in
            if imageURL != nil, ready { SDKInstance.shared.reportGuideShown() }
        }
        .task(id: imageURL) {
            targetImage = nil
            imageLoaded = false
            guard let imageURL else { return }
            AnchorlessImageLoader.prefetch(nextImageURL)
            guard let decoded = await AnchorlessImageLoader.image(for: imageURL) else {
                SDKInstance.shared.reportGuideRenderFailure(nil)
                return
            }
            targetImage = decoded
            imageLoaded = true
        }
        .task(id: stepIndex) {
            delayElapsedForStep = nil
            if imageURL != nil {
                let delayMs = step.delayInMs ?? 0
                guard delayMs > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                if !Task.isCancelled { delayElapsedForStep = stepIndex }
                return
            }
            guard step.advanceTrigger == "auto", let delayMs = step.autoDelayMs, delayMs > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            if !Task.isCancelled { onAdvance() }
        }
    }

    private var bubbleBackground: Color { guideColor(config.bubble.backgroundColor, fallback: Color(.sRGB, red: 0.12, green: 0.25, blue: 0.69, opacity: 1)) }

    @ViewBuilder
    private func positionedBubble(
        viewportSize: CGSize,
        origin: CGPoint,
        isAnchorless: Bool
    ) -> some View {
        if isAnchorless {
            bubble(viewportSize: viewportSize)
                .frame(width: min(CGFloat(config.bubble.maxWidthDp), viewportSize.width - 32))
                .background(bubbleSizeReader)
                .position(
                    x: origin.x + bubbleSize.width / 2,
                    y: origin.y + bubbleSize.height / 2
                )
                .opacity(bubbleSize == .zero ? 0 : 1)
        } else {
            bubble(viewportSize: viewportSize)
                .frame(maxWidth: CGFloat(config.bubble.maxWidthDp))
                .background(bubbleSizeReader)
                .position(
                    x: origin.x + bubbleSize.width / 2,
                    y: origin.y + bubbleSize.height / 2
                )
                .opacity(bubbleSize == .zero ? 0 : 1)
        }
    }

    private var bubbleSizeReader: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { bubbleSize = geometry.size }
                .onChange(of: geometry.size) { bubbleSize = $0 }
        }
    }

    @ViewBuilder
    private func bubble(viewportSize: CGSize) -> some View {
        if imageURL != nil, let canvas = config.canvas {
            GuideCampaignCanvasView(
                canvas: canvas,
                designWidth: designWidth,
                viewportWidth: viewportSize.width,
                availableSize: CGSize(
                    width: min(CGFloat(config.bubble.maxWidthDp), viewportSize.width - 32),
                    height: viewportSize.height - 32
                ),
                cornerRadius: CGFloat(config.bubble.cornerRadius),
                onAction: handleCanvasAction
            )
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat(config.bubble.cornerRadius))
                    .stroke(
                        guideColor(config.bubble.borderColor, fallback: .clear),
                        lineWidth: CGFloat(config.bubble.borderWidth)
                    )
            )
            .shadow(radius: CGFloat(config.bubble.elevation))
        } else {
            classicBubble
        }
    }

    private var classicBubble: some View {
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
                        Button(action: { handleAction(action) }) {
                            Text(interpolate(action.label, context: variables))
                                .font(
                                    Font(SDKInstance.shared.font.resolve(
                                        size: action.fontSize,
                                        weight: action.fontWeight,
                                        italic: false
                                    ))
                                )
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

    private func handleCanvasAction(_ request: CampaignCanvasActionRequest) {
        let reportedAction = request.actions.first?.resolved(with: variables)
        SDKInstance.shared.reportGuideStepClicked(
            actionType: reportedAction?.analyticsType,
            actionUrl: reportedAction?.analyticsURL,
            ctaLabel: request.label,
            action: reportedAction,
            elementId: request.elementId
        )
        Task {
            await SDKInstance.shared.executeActionFlow(
                request.actions,
                variables: variables,
                localActionExecutor: LocalActionExecutor(
                    dismiss: onDismiss,
                    next: onAdvance,
                    previous: { SDKInstance.shared.previousGuide() }
                )
            )
        }
    }

    private func handleAction(_ action: GuideAction) {
        guard SDKInstance.shared.guideOrchestrator.state != nil else { return }
        let reportedAction = action.actions.first?.resolved(with: variables)
        SDKInstance.shared.reportGuideStepClicked(
            actionType: reportedAction?.analyticsType,
            actionUrl: reportedAction?.analyticsURL,
            ctaLabel: interpolate(action.label, context: variables),
            action: reportedAction
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
    let isAuto = preferred == "auto"
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
    if isAuto {
        let candidates: [(CalloutPlacement, Bool)] = [
            (.below, fitsBelow),
            (.above, fitsAbove),
            (.right, fitsRight),
            (.left, fitsLeft),
        ]
        return candidates.first(where: { $0.1 })?.0 ?? .below
    }
    switch requested {
    case .above: return fitsAbove || !fitsBelow ? .above : .below
    case .below: return fitsBelow || !fitsAbove ? .below : .above
    case .left: return fitsLeft || !fitsRight ? .left : .right
    case .right: return fitsRight || !fitsLeft ? .right : .left
    }
}

private func resolvedClassicPlacement(
    preferred: String,
    anchor: CGRect,
    bubble: CGSize,
    screen: CGSize
) -> CalloutPlacement {
    switch preferred {
    case "top": return .below
    case "bottom", "start", "end": return .above
    default:
        let spaceBelow = screen.height - anchor.maxY
        return spaceBelow >= bubble.height + 24 || spaceBelow >= anchor.minY ? .below : .above
    }
}

private func classicArrowPosition(
    placement: CalloutPlacement,
    anchor: CGRect,
    screenWidth: CGFloat
) -> CGPoint {
    CGPoint(
        x: min(max(anchor.midX, 17), screenWidth - 17),
        y: placement == .below ? anchor.maxY + 7 : anchor.minY - 7
    )
}

private func classicBubbleOrigin(
    placement: CalloutPlacement,
    anchor: CGRect,
    bubble: CGSize,
    screenWidth: CGFloat,
    maxWidth: CGFloat
) -> CGPoint {
    let centerX = min(
        max(anchor.midX, maxWidth / 2 + 8),
        screenWidth - maxWidth / 2 - 8
    )
    return CGPoint(
        x: centerX - bubble.width / 2,
        y: placement == .below
            ? anchor.maxY + 24
            : anchor.minY - 24 - bubble.height
    )
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
    let inset = max(cornerRadius, arrowSize)
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
    let isAnchorless: Bool
    let color: Color
    let alpha: Double

    var body: some View {
        let pad = CGFloat(cutout.padding)
        let hole = anchorRect.insetBy(dx: -pad, dy: -pad)
        let shape = GuideCutoutShape(shape: cutout.shape, cornerRadius: cornerRadius)

        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(alpha)))
            context.blendMode = .clear
            let path = isAnchorless
                ? shape.path(in: hole)
                : (cutout.shape == "rect"
                    ? Path(hole)
                    : Path(
                        roundedRect: hole,
                            cornerRadius: cutout.shape == "circle"
                            ? max(hole.width, hole.height) / 2
                            : CGFloat(cutout.cornerRadius)
                    ))
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
