import SwiftUI
import Combine
import UIKit

@MainActor
private enum AnchorlessImageLoader {
    private static let cache = NSCache<NSURL, UIImage>()
    private static let imageLoadTimeout: TimeInterval = 3

    static func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        var request = URLRequest(url: url)
        request.timeoutInterval = imageLoadTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled,
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = UIImage(data: data)
        else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    static func prefetch(_ url: URL?) {
        guard let url else { return }
        Task { _ = await image(for: url) }
    }
}

// Native multi-step guide renderer (tooltip / spotlight), ported from Android's
// `GuideRenderer.kt`. Driven by GuideOrchestrator state and styled entirely from
// GuideStepWidgetConfig (no SDUI viewId), positioned against a registered anchor.
@MainActor
struct GuideOverlayView: View {
    @ObservedObject private var orchestrator = SDKInstance.shared.guideOrchestrator
    @ObservedObject private var anchors = AnchorRegistry.shared

    var body: some View {
        Group {
            if let state = orchestrator.state, let step = state.currentStep {
                switch resolve(state, cornerRadius: step.widgetConfig.overlay.cutout.cornerRadius) {
                case let .ready(anchorRect, cornerRadius, imageURL):
                    GuideStepOverlay(
                        step: step,
                        guideToken: state.token,
                        stepIndex: state.stepIndex,
                        totalSteps: state.steps.count,
                        designWidth: state.campaign.guideConfig?.designWidth
                            ?? defaultCampaignCanvasDesignWidth,
                        anchorRect: anchorRect,
                        safeAreaInsets: keyWindow?.safeAreaInsets ?? .zero,
                        cornerRadius: cornerRadius,
                        imageURL: imageURL,
                        nextImageURL: state.steps.indices.contains(state.stepIndex + 1)
                            ? state.steps[state.stepIndex + 1].target.anchorlessTarget?.imageURL
                            : nil,
                        onAdvance: { SDKInstance.shared.advanceGuide() },
                        onOutsideTap: { SDKInstance.shared.advanceGuide(completesOnLast: false) },
                        onDismiss: { SDKInstance.shared.dismissGuide() }
                    )
                    .environment(\.digiaVariables, state.variableContext)
                    .id(state.stepIndex)
                case .notReady:
                    EmptyView()
                case let .failed(failure):
                    Color.clear.task(id: "\(state.token):\(state.campaign.id):\(state.stepIndex):\(failure.rawValue)") {
                        SDKInstance.shared.reportGuideRenderFailure(
                            failure,
                            guideToken: state.token,
                            stepIndex: state.stepIndex
                        )
                    }
                }
            } else {
                EmptyView()
            }
        }
        .ignoresSafeArea()
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
            guard let rect = anchors.availableRect(for: anchorKey) else { return .notReady }
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
        ViewControllerUtil.keyWindow()
    }
}

private enum GuideResolvedTarget {
    case ready(CGRect, CGFloat, URL?)
    case notReady
    case failed(AnchorlessFailure)
}

private struct GuideStepOverlay: View {
    let step: GuideStepModel
    let guideToken: Int64
    let stepIndex: Int
    let totalSteps: Int
    let designWidth: CGFloat
    let anchorRect: CGRect
    let safeAreaInsets: UIEdgeInsets
    let cornerRadius: CGFloat
    let imageURL: URL?
    let nextImageURL: URL?
    let onAdvance: () -> Void
    let onOutsideTap: () -> Void
    let onDismiss: () -> Void

    @Environment(\.digiaVariables) private var variables
    @State private var bubbleSize: CGSize = .zero
    @State private var targetImage: UIImage?
    @State private var imageLoaded = false
    @State private var delayElapsedForStep: Int?

    private var config: GuideStepWidgetConfig { step.widgetConfig }
    private var isSpotlight: Bool { config.overlay.visible }
    private var isPresentationReady: Bool {
        guard bubbleSize != .zero else { return false }
        let delayElapsed = (step.delayInMs ?? 0) <= 0 || delayElapsedForStep == stepIndex
        guard delayElapsed else { return false }
        return imageURL == nil || imageLoaded
    }

    var body: some View {
        GeometryReader { geo in
            let isAnchorless = imageURL != nil
            let isFlat = config.schema == .flat
            let isCanvas = config.canvas != nil && config.layoutMode == "canvas"
            let canvasScale = isCanvas
                ? anchorlessDesignScale(hostWidth: geo.size.width, designWidth: designWidth) ?? 1
                : 1
            let safeBounds = CGRect(
                x: safeAreaInsets.left,
                y: safeAreaInsets.top,
                width: max(0, geo.size.width - safeAreaInsets.left - safeAreaInsets.right),
                height: max(0, geo.size.height - safeAreaInsets.top - safeAreaInsets.bottom)
            )
            let arrowSize = isAnchorless || isFlat
                ? CGFloat(config.bubble.arrow.size)
                : 10
            let arrowVisible = config.bubble.arrow.visible
            let gap = isCanvas
                ? CGFloat(config.bubble.calloutGap) * canvasScale
                : isAnchorless || isFlat
                ? CGFloat(config.bubble.calloutGap)
                : 24
            let paddedAnchor = isFlat && isSpotlight && !isAnchorless
                ? anchorRect.insetBy(
                    dx: -CGFloat(config.overlay.cutout.padding) * canvasScale,
                    dy: -CGFloat(config.overlay.cutout.padding) * canvasScale
                )
                : anchorRect
            let placementAnchor = paddedAnchor
            let canvasPlacement: GuideCanvasPlacement? = if isCanvas && !isAnchorless, let canvas = config.canvas {
                guideCanvasPlacement(
                    canvas: canvas,
                    preferred: config.bubble.arrow.preferredDirection,
                    anchor: placementAnchor,
                    bounds: safeBounds.insetBy(dx: 16, dy: 16),
                    desiredScale: canvasScale,
                    pointerSize: arrowVisible ? arrowSize : 0,
                    gap: CGFloat(config.bubble.calloutGap)
                )
            } else {
                nil
            }
            let placement = if let canvasPlacement {
                canvasPlacement.side
            } else if isAnchorless {
                resolvedAnchorlessPlacement(
                    preferred: config.bubble.arrow.preferredDirection,
                    anchor: placementAnchor,
                    bubble: bubbleSize,
                    screen: safeBounds,
                    gap: gap
                )
            } else if isFlat {
                resolvedPlacement(
                    preferred: config.bubble.arrow.preferredDirection,
                    anchor: placementAnchor,
                    bubble: bubbleSize,
                    screen: safeBounds,
                    gap: gap
                )
            } else {
                resolvedClassicPlacement(
                    preferred: config.bubble.arrow.preferredDirection,
                    anchor: anchorRect,
                    bubble: bubbleSize,
                    screen: safeBounds
                )
            }
            let bubbleOrigin = if let canvasPlacement {
                canvasPlacement.origin
            } else if isAnchorless || isFlat {
                calloutOrigin(
                    placement: placement,
                    anchor: placementAnchor,
                    bubble: bubbleSize,
                    screen: safeBounds,
                    gap: gap
                )
            } else {
                classicBubbleOrigin(
                    placement: placement,
                    anchor: anchorRect,
                    bubble: bubbleSize,
                    screen: safeBounds,
                    maxWidth: CGFloat(config.bubble.maxWidthDp)
                )
            }
            let arrowPosition = isAnchorless || isFlat
                ? calloutArrowPosition(
                    placement: placement,
                    anchor: paddedAnchor,
                    bubbleOrigin: bubbleOrigin,
                    bubble: bubbleSize,
                    cornerRadius: CGFloat(config.bubble.cornerRadius),
                    arrowSize: arrowSize,
                    screen: safeBounds
                )
                : classicArrowPosition(
                    placement: placement,
                    anchor: anchorRect,
                    screen: safeBounds
                )
            let arrowOverlap = max(1, CGFloat(config.bubble.borderWidth))
            let arrowOffset = switch placement {
            case .above: CGSize(width: 0, height: -arrowOverlap)
            case .below: CGSize(width: 0, height: arrowOverlap)
            case .left: CGSize(width: -arrowOverlap, height: 0)
            case .right: CGSize(width: arrowOverlap, height: 0)
            }

            ZStack(alignment: .topLeading) {
                // Background: spotlight scrim with cutout, or transparent tap-to-dismiss.
                if isSpotlight {
                    GuideSpotlightScrim(
                        anchorRect: anchorRect,
                        cutout: config.overlay.cutout,
                        cornerRadius: isFlat && !isAnchorless
                            ? CGFloat(config.overlay.cutout.cornerRadius) * canvasScale
                            : cornerRadius,
                        isAnchorless: isAnchorless,
                        usesFlatSchema: isFlat,
                        geometryScale: canvasScale,
                        color: guideColor(config.overlay.color, fallback: .black),
                        alpha: config.overlay.alpha
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isAnchorless {
                            if config.overlay.dismissOnTap { onAdvance() }
                        } else if isFlat {
                            if config.outsideTapBehavior == .next { onOutsideTap() }
                        } else if config.overlay.dismissOnTap {
                            onDismiss()
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isFlat {
                                if config.outsideTapBehavior == .next { onOutsideTap() }
                            } else {
                                onDismiss()
                            }
                        }
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
                            cornerRadius: isFlat && !isAnchorless
                                ? CGFloat(config.overlay.cutout.cornerRadius)
                                : cornerRadius
                        )
                    )
                    .position(x: anchorRect.midX, y: anchorRect.midY)
                }

                positionedBubble(
                    viewportSize: geo.size,
                    availableSize: safeBounds.size,
                    origin: bubbleOrigin,
                    fixedWidth: isAnchorless || isFlat,
                    resolvedCanvasScale: canvasPlacement?.scale,
                    canvasPointerDirection: isCanvas && arrowVisible ? placement.canvasPointerDirection : nil,
                    canvasPointerSize: isCanvas && arrowVisible ? arrowSize : 0,
                    canvasPointerCenter: isCanvas && arrowVisible
                        ? (placement.isVertical ? placementAnchor.midX - bubbleOrigin.x : placementAnchor.midY - bubbleOrigin.y)
                        : nil
                )

                if arrowVisible && bubbleSize != .zero && !isCanvas {
                    GuideArrow(
                        direction: placement.arrowDirection,
                        color: guideColor(config.bubble.arrow.color, fallback: bubbleBackground),
                        borderColor: guideColor(config.bubble.borderColor, fallback: .clear),
                        borderWidth: isFlat ? CGFloat(config.bubble.borderWidth) : 0
                    )
                        .frame(
                            width: isAnchorless || isFlat
                                ? (placement.isVertical ? arrowSize * 2 : arrowSize)
                                : 18,
                            height: isAnchorless || isFlat
                                ? (placement.isVertical ? arrowSize : arrowSize * 2)
                                : 10
                        )
                        .position(arrowPosition)
                        .offset(x: arrowOffset.width, y: arrowOffset.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .opacity(isPresentationReady ? 1 : 0)
            .allowsHitTesting(isPresentationReady)
        }
        .onAppear {
            if isPresentationReady { SDKInstance.shared.reportGuideShown() }
        }
        .onChange(of: isPresentationReady) { ready in
            if ready { SDKInstance.shared.reportGuideShown() }
        }
        .task(id: imageURL) {
            targetImage = nil
            imageLoaded = false
            guard let imageURL else { return }
            AnchorlessImageLoader.prefetch(nextImageURL)
            guard let decoded = await AnchorlessImageLoader.image(for: imageURL) else {
                guard !Task.isCancelled else { return }
                SDKInstance.shared.reportGuideRenderFailure(
                    nil,
                    guideToken: guideToken,
                    stepIndex: stepIndex
                )
                return
            }
            guard !Task.isCancelled else { return }
            targetImage = decoded
            imageLoaded = true
        }
        .task(id: stepIndex) {
            delayElapsedForStep = nil
            let delayMs = step.delayInMs ?? 0
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: guideDelayNanoseconds(delayMs))
                guard !Task.isCancelled else { return }
                delayElapsedForStep = stepIndex
            }
            if imageURL != nil { return }
            guard step.advanceTrigger == "auto", let delayMs = step.autoDelayMs, delayMs > 0 else { return }
            try? await Task.sleep(nanoseconds: guideDelayNanoseconds(delayMs))
            if !Task.isCancelled {
                if config.schema == .flat { onOutsideTap() } else { onAdvance() }
            }
        }
    }

    private var bubbleBackground: Color { guideColor(config.bubble.backgroundColor, fallback: Color(.sRGB, red: 0.12, green: 0.25, blue: 0.69, opacity: 1)) }

    @ViewBuilder
    private func positionedBubble(
        viewportSize: CGSize,
        availableSize: CGSize,
        origin: CGPoint,
        fixedWidth: Bool,
        resolvedCanvasScale: CGFloat?,
        canvasPointerDirection: GuideCanvasPointerDirection?,
        canvasPointerSize: CGFloat,
        canvasPointerCenter: CGFloat?
    ) -> some View {
        if config.canvas != nil && config.layoutMode == "canvas" {
            bubble(
                viewportSize: viewportSize,
                availableSize: availableSize,
                resolvedCanvasScale: resolvedCanvasScale,
                canvasPointerDirection: canvasPointerDirection,
                canvasPointerSize: canvasPointerSize,
                canvasPointerCenter: canvasPointerCenter
            )
                .background(bubbleSizeReader)
                .position(
                    x: origin.x + bubbleSize.width / 2,
                    y: origin.y + bubbleSize.height / 2
                )
                .opacity(bubbleSize == .zero ? 0 : 1)
        } else if fixedWidth {
            let width = max(0, min(CGFloat(config.bubble.maxWidthDp), availableSize.width - 32))
            bubble(
                viewportSize: viewportSize,
                availableSize: availableSize,
                resolvedCanvasScale: resolvedCanvasScale,
                canvasPointerDirection: canvasPointerDirection,
                canvasPointerSize: canvasPointerSize,
                canvasPointerCenter: canvasPointerCenter
            )
                .frame(width: width)
                .background(bubbleSizeReader)
                .position(
                    x: origin.x + bubbleSize.width / 2,
                    y: origin.y + bubbleSize.height / 2
                )
                .opacity(bubbleSize == .zero ? 0 : 1)
        } else {
            bubble(
                viewportSize: viewportSize,
                availableSize: availableSize,
                resolvedCanvasScale: resolvedCanvasScale,
                canvasPointerDirection: canvasPointerDirection,
                canvasPointerSize: canvasPointerSize,
                canvasPointerCenter: canvasPointerCenter
            )
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
    private func bubble(
        viewportSize: CGSize,
        availableSize: CGSize,
        resolvedCanvasScale: CGFloat?,
        canvasPointerDirection: GuideCanvasPointerDirection? = nil,
        canvasPointerSize: CGFloat = 0,
        canvasPointerCenter: CGFloat? = nil
    ) -> some View {
        if let canvas = config.canvas, config.layoutMode == "canvas" {
            GuideCanvasUnionSurface(
                canvas: canvas,
                designWidth: designWidth,
                viewportWidth: viewportSize.width,
                availableSize: CGSize(
                    width: max(0, availableSize.width - 32),
                    height: max(0, availableSize.height - 32)
                ),
                resolvedScale: resolvedCanvasScale,
                cornerRadius: CGFloat(config.bubble.cornerRadius),
                pointerDirection: canvasPointerDirection,
                pointerSize: canvasPointerSize,
                pointerCenter: canvasPointerCenter,
                borderColor: guideColor(config.bubble.borderColor, fallback: .clear),
                borderWidth: CGFloat(config.bubble.borderWidth),
                shadowRadius: CGFloat(config.bubble.elevation),
                onAction: handleCanvasAction
            )
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
                HStack(spacing: config.schema == .flat ? 0 : 8) {
                    Spacer()
                    ForEach(Array(config.actions.enumerated()), id: \.offset) { _, action in
                        guideActionButton(action)
                    }
                }
                .padding(.top, config.schema == .flat ? 12 : 4)
            }
        }
        .padding(.horizontal, CGFloat(config.bubble.paddingHorizontal))
        .padding(.vertical, CGFloat(config.bubble.paddingVertical))
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(config.bubble.cornerRadius)))
        .overlay {
            if config.schema == .flat && config.bubble.borderWidth > 0 {
                RoundedRectangle(cornerRadius: CGFloat(config.bubble.cornerRadius))
                    .stroke(
                        guideColor(config.bubble.borderColor, fallback: .clear),
                        lineWidth: CGFloat(config.bubble.borderWidth)
                    )
            }
        }
        .shadow(
            color: config.schema == .flat
                ? .black.opacity(config.bubble.elevation > 0 ? 0.15 : 0)
                : .black.opacity(0.33),
            radius: config.schema == .flat && config.bubble.elevation > 0
                ? 12
                : CGFloat(config.bubble.elevation),
            x: 0,
            y: config.schema == .flat && config.bubble.elevation > 0 ? 4 : 0
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if config.schema == .flat, !isSpotlight, config.outsideTapBehavior == .next {
                onOutsideTap()
            }
        }
    }

    @ViewBuilder
    private func guideActionButton(_ action: GuideAction) -> some View {
        if config.schema == .flat {
            Button(action: { handleAction(action) }) {
                actionLabel(action)
                    .foregroundColor(
                        guideColor(
                            action.style == "fill" || action.style == "elevated"
                                ? action.textColor : action.backgroundColor,
                            fallback: bubbleBackground
                        )
                    )
                    .padding(action.edgeInsets)
                    .background(
                        action.style == "fill" || action.style == "elevated"
                            ? guideColor(action.backgroundColor, fallback: .white)
                            : .clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(action.cornerRadius)))
                    .overlay {
                        if action.style == "outline" {
                            RoundedRectangle(cornerRadius: CGFloat(action.cornerRadius))
                                .stroke(
                                    guideColor(action.backgroundColor, fallback: .clear),
                                    lineWidth: 1.5
                                )
                        }
                    }
                    .shadow(radius: action.style == "elevated" ? 2 : 0)
            }
            .buttonStyle(.plain)
            .padding(action.marginInsets)
        } else {
            Button(action: { handleAction(action) }) {
                actionLabel(action)
                    .foregroundColor(guideColor(action.textColor, fallback: bubbleBackground))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(guideColor(action.backgroundColor, fallback: .white))
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(action.cornerRadius)))
            }
        }
    }

    private func actionLabel(_ action: GuideAction) -> some View {
        Text(interpolate(action.label, context: variables))
            .font(
                Font(SDKInstance.shared.font.resolve(
                    size: action.fontSize,
                    weight: action.fontWeight,
                    italic: false
                ))
            )
    }

    private func handleCanvasAction(_ request: CampaignCanvasActionRequest) {
        let reportedAction = request.actions.first?.resolved(with: variables)
        SDKInstance.shared.reportGuideStepClicked(
            actionType: reportedAction?.analyticsType,
            actionUrl: reportedAction?.analyticsURL,
            ctaLabel: request.label ?? request.elementId,
            action: reportedAction,
            elementId: request.elementId
        )
        Task {
            await SDKInstance.shared.executeGuideActionFlow(
                guideActions(request.actions),
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
        let executableActions = config.schema == .flat
            ? guideActions(action.actions)
            : action.actions
        SDKInstance.shared.reportGuideStepClicked(
            actionType: reportedAction?.analyticsType
                ?? (action.fireEventName == nil ? nil : "fire_event"),
            actionUrl: reportedAction?.analyticsURL,
            ctaLabel: interpolate(action.label, context: variables),
            action: reportedAction
        )
        if let eventName = action.fireEventName {
            SDKInstance.shared.fireGuideEvent(eventName)
        }
        Task {
            await SDKInstance.shared.executeGuideActionFlow(
                executableActions,
                variables: variables,
                localActionExecutor: LocalActionExecutor(
                    dismiss: onDismiss,
                    next: onAdvance,
                    previous: { SDKInstance.shared.previousGuide() }
                )
            )
        }
    }

    private func guideActions(_ actions: [EngageAction]) -> [EngageAction] {
        var result: [EngageAction] = []
        for (index, action) in actions.enumerated() {
            result.append(action)
            if action.isLink, actions.indices.contains(index + 1), actions[index + 1] == .dismiss {
                continue
            }
            if action.isLink { result.append(.dismiss) }
        }
        return result
    }
}

private struct GuideCanvasPlacement {
    let scale: CGFloat
    let side: CalloutPlacement
    let origin: CGPoint
}

private func guideCanvasPlacement(
    canvas: CampaignCanvas,
    preferred: String,
    anchor: CGRect,
    bounds: CGRect,
    desiredScale: CGFloat,
    pointerSize: CGFloat,
    gap: CGFloat
) -> GuideCanvasPlacement {
    let requested: CalloutPlacement = switch preferred {
    case "above", "top": .above
    case "below", "bottom": .below
    case "left", "start": .left
    case "right", "end": .right
    default: .below
    }
    let sides: [CalloutPlacement] = switch requested {
    case .above: [.above, .below, .right, .left]
    case .below: [.below, .above, .right, .left]
    case .left: [.left, .right, .below, .above]
    case .right: [.right, .left, .below, .above]
    }
    let candidates = sides.map { side in
        let availablePrimary: CGFloat = switch side {
        case .above: anchor.minY - bounds.minY
        case .below: bounds.maxY - anchor.maxY
        case .left: anchor.minX - bounds.minX
        case .right: bounds.maxX - anchor.maxX
        }
        let primary = side.isVertical ? canvas.height : canvas.width
        let cross = side.isVertical ? canvas.width : canvas.height
        let availableCross = side.isVertical ? bounds.width : bounds.height
        let scale = max(
            0,
            min(
                desiredScale,
                max(0, availablePrimary) / max(primary + pointerSize + gap, 1),
                max(0, availableCross) / max(cross, 1)
            )
        )
        return (side: side, scale: scale)
    }
    let firstCandidate = candidates.first ?? (side: .below, scale: 0)
    let selected = candidates.first(where: { $0.scale >= desiredScale })
        ?? candidates.dropFirst().reduce(firstCandidate) { best, candidate in
            candidate.scale > best.scale ? candidate : best
        }
    let scale = selected.scale
    let side = selected.side
    let surfaceSize = CGSize(
        width: (canvas.width + (side.isVertical ? 0 : pointerSize)) * scale,
        height: (canvas.height + (side.isVertical ? pointerSize : 0)) * scale
    )
    let scaledGap = gap * scale
    let rawOrigin: CGPoint = switch side {
    case .above:
        CGPoint(x: anchor.midX - surfaceSize.width / 2, y: anchor.minY - scaledGap - surfaceSize.height)
    case .below:
        CGPoint(x: anchor.midX - surfaceSize.width / 2, y: anchor.maxY + scaledGap)
    case .left:
        CGPoint(x: anchor.minX - scaledGap - surfaceSize.width, y: anchor.midY - surfaceSize.height / 2)
    case .right:
        CGPoint(x: anchor.maxX + scaledGap, y: anchor.midY - surfaceSize.height / 2)
    }
    let origin = if side.isVertical {
        CGPoint(
            x: min(max(rawOrigin.x, bounds.minX), max(bounds.minX, bounds.maxX - surfaceSize.width)),
            y: rawOrigin.y
        )
    } else {
        CGPoint(
            x: rawOrigin.x,
            y: min(max(rawOrigin.y, bounds.minY), max(bounds.minY, bounds.maxY - surfaceSize.height))
        )
    }
    return GuideCanvasPlacement(scale: scale, side: side, origin: origin)
}

private extension GuideAction {
    var edgeInsets: EdgeInsets {
        EdgeInsets(
            top: padding.top,
            leading: padding.left,
            bottom: padding.bottom,
            trailing: padding.right
        )
    }

    var marginInsets: EdgeInsets {
        EdgeInsets(
            top: margin.top,
            leading: margin.left,
            bottom: margin.bottom,
            trailing: margin.right
        )
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

    var canvasPointerDirection: GuideCanvasPointerDirection {
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
    screen: CGRect,
    gap: CGFloat
) -> CalloutPlacement {
    let requested: CalloutPlacement = switch preferred {
    case "above", "top": .above
    case "below", "bottom": .below
    case "left", "start": .left
    case "right", "end": .right
    default: .below
    }
    guard bubble != .zero else { return requested }
    let margin: CGFloat = 16
    let fitsAbove = anchor.minY - gap - bubble.height >= screen.minY + margin
    let fitsBelow = anchor.maxY + gap + bubble.height <= screen.maxY - margin
    let fitsLeft = anchor.minX - gap - bubble.width >= screen.minX + margin
    let fitsRight = anchor.maxX + gap + bubble.width <= screen.maxX - margin
    switch requested {
    case .above: return fitsAbove || !fitsBelow ? .above : .below
    case .below: return fitsBelow || !fitsAbove ? .below : .above
    case .left: return fitsLeft || !fitsRight ? .left : .right
    case .right: return fitsRight || !fitsLeft ? .right : .left
    }
}

private func resolvedAnchorlessPlacement(
    preferred: String,
    anchor: CGRect,
    bubble: CGSize,
    screen: CGRect,
    gap: CGFloat
) -> CalloutPlacement {
    let isAuto = preferred == "auto"
    let requested: CalloutPlacement = switch preferred {
    case "above", "top": .above
    case "below", "bottom": .below
    case "left", "start": .left
    case "right", "end": .right
    default: .below
    }
    guard bubble != .zero else { return requested }
    let margin: CGFloat = 16
    let fitsAbove = anchor.minY - gap - bubble.height >= screen.minY + margin
    let fitsBelow = anchor.maxY + gap + bubble.height <= screen.maxY - margin
    let fitsLeft = anchor.minX - gap - bubble.width >= screen.minX + margin
    let fitsRight = anchor.maxX + gap + bubble.width <= screen.maxX - margin
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
    screen: CGRect
) -> CalloutPlacement {
    switch preferred {
    case "top": return .below
    case "bottom", "start", "end": return .above
    default:
        let spaceBelow = screen.maxY - anchor.maxY
        return spaceBelow >= bubble.height + 24 || spaceBelow >= anchor.minY ? .below : .above
    }
}

private func classicArrowPosition(
    placement: CalloutPlacement,
    anchor: CGRect,
    screen: CGRect
) -> CGPoint {
    CGPoint(
        x: min(max(anchor.midX, screen.minX + 17), screen.maxX - 17),
        y: placement == .below ? anchor.maxY + 7 : anchor.minY - 7
    )
}

private func classicBubbleOrigin(
    placement: CalloutPlacement,
    anchor: CGRect,
    bubble: CGSize,
    screen: CGRect,
    maxWidth: CGFloat
) -> CGPoint {
    let centerX = min(
        max(anchor.midX, screen.minX + maxWidth / 2 + 8),
        screen.maxX - maxWidth / 2 - 8
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
    screen: CGRect,
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
    if placement.isVertical {
        return CGPoint(
            x: min(
                max(raw.x, screen.minX + margin),
                max(screen.minX + margin, screen.maxX - margin - bubble.width)
            ),
            y: raw.y
        )
    }
    return CGPoint(
        x: raw.x,
        y: min(
            max(raw.y, screen.minY + margin),
            max(screen.minY + margin, screen.maxY - margin - bubble.height)
        )
    )
}

private func calloutArrowPosition(
    placement: CalloutPlacement,
    anchor: CGRect,
    bubbleOrigin: CGPoint,
    bubble: CGSize,
    cornerRadius: CGFloat,
    arrowSize: CGFloat,
    screen: CGRect
) -> CGPoint {
    let inset = cornerRadius + arrowSize + 2
    if placement.isVertical {
        let x = min(
            max(anchor.midX, bubbleOrigin.x + inset),
            min(bubbleOrigin.x + bubble.width - inset, screen.maxX - inset)
        )
        let y = placement == .below
            ? bubbleOrigin.y - arrowSize / 2
            : bubbleOrigin.y + bubble.height + arrowSize / 2
        return CGPoint(x: x, y: y)
    }
    let y = min(
        max(anchor.midY, bubbleOrigin.y + inset),
        min(bubbleOrigin.y + bubble.height - inset, screen.maxY - inset)
    )
    let x = placement == .right
        ? bubbleOrigin.x - arrowSize / 2
        : bubbleOrigin.x + bubble.width + arrowSize / 2
    return CGPoint(x: x, y: y)
}

private struct GuideArrow: View {
    let direction: GuideArrowDirection
    let color: Color
    let borderColor: Color
    let borderWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let triangle = Path { path in
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
            let innerTriangle = Path { path in
                let w = geo.size.width
                let h = geo.size.height
                let inset = borderWidth * (sqrt(2) - 1)
                let tipInset = borderWidth + inset
                switch direction {
                case .up:
                    path.move(to: CGPoint(x: w / 2, y: tipInset))
                    path.addLine(to: CGPoint(x: w - inset, y: h))
                    path.addLine(to: CGPoint(x: inset, y: h))
                case .down:
                    path.move(to: CGPoint(x: inset, y: 0))
                    path.addLine(to: CGPoint(x: w - inset, y: 0))
                    path.addLine(to: CGPoint(x: w / 2, y: h - tipInset))
                case .left:
                    path.move(to: CGPoint(x: tipInset, y: h / 2))
                    path.addLine(to: CGPoint(x: w, y: inset))
                    path.addLine(to: CGPoint(x: w, y: h - inset))
                case .right:
                    path.move(to: CGPoint(x: 0, y: inset))
                    path.addLine(to: CGPoint(x: w - tipInset, y: h / 2))
                    path.addLine(to: CGPoint(x: 0, y: h - inset))
                }
                path.closeSubpath()
            }
            if borderWidth > 0 {
                triangle.fill(borderColor)
                innerTriangle.fill(color)
            } else {
                triangle.fill(color)
            }
        }
    }
}

private struct GuideSpotlightScrim: View {
    let anchorRect: CGRect
    let cutout: CutoutConfig
    let cornerRadius: CGFloat
    let isAnchorless: Bool
    let usesFlatSchema: Bool
    let geometryScale: CGFloat
    let color: Color
    let alpha: Double

    var body: some View {
        let pad = isAnchorless ? 0 : CGFloat(cutout.padding) * geometryScale
        let hole = anchorRect.insetBy(dx: -pad, dy: -pad)
        let shape = GuideCutoutShape(shape: cutout.shape, cornerRadius: cornerRadius)

        Canvas { context, size in
            let safeAlpha = alpha.isFinite ? min(max(alpha, 0), 1) : 0
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(safeAlpha)))
            context.blendMode = .clear
            let path = isAnchorless || usesFlatSchema
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
                let glowWidth = cutout.glowWidth.isFinite
                    ? min(max(CGFloat(cutout.glowWidth) * geometryScale, 0), 48)
                    : 0
                let blurRadius = max(2, glowWidth * 1.5) / 2
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addPath(path)
                context.drawLayer { glow in
                    glow.clip(to: outside, style: FillStyle(eoFill: true))
                    glow.addFilter(.blur(radius: blurRadius))
                    glow.stroke(
                        path,
                        with: .color(guideColor(cutout.glowColor, fallback: .clear)),
                        lineWidth: glowWidth * 2
                    )
                }
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

private func guideDelayNanoseconds(_ milliseconds: Int) -> UInt64 {
    let value = UInt64(milliseconds)
    return value > UInt64.max / 1_000_000
        ? UInt64.max
        : value * 1_000_000
}

private func guideColor(_ hex: String, fallback: Color) -> Color {
    Color(hex: hex) ?? fallback
}
