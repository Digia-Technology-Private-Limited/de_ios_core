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
                        campaignID: state.payload.cepCampaignId,
                        guideToken: state.token,
                        stepIndex: state.stepIndex,
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
                    .id("\(state.token):\(state.stepIndex)")
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
    let campaignID: String
    let guideToken: Int64
    let stepIndex: Int
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
            let canvasScale = anchorlessDesignScale(hostWidth: geo.size.width, designWidth: designWidth) ?? 1
            let safeBounds = CGRect(
                x: safeAreaInsets.left,
                y: safeAreaInsets.top,
                width: max(0, geo.size.width - safeAreaInsets.left - safeAreaInsets.right),
                height: max(0, geo.size.height - safeAreaInsets.top - safeAreaInsets.bottom)
            )
            let arrowSize = CGFloat(config.bubble.arrow.size)
            let arrowVisible = config.bubble.arrow.visible
            let gap = CGFloat(config.bubble.calloutGap) * canvasScale
            let paddedAnchor = isSpotlight && !isAnchorless
                ? anchorRect.insetBy(
                    dx: -CGFloat(config.overlay.cutout.padding) * canvasScale,
                    dy: -CGFloat(config.overlay.cutout.padding) * canvasScale
                )
                : anchorRect
            let placementAnchor = paddedAnchor
            let canvasPlacement: GuideCanvasPlacement? = if !isAnchorless, let canvas = config.canvas {
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
            } else {
                resolvedAnchorlessPlacement(
                    preferred: config.bubble.arrow.preferredDirection,
                    anchor: placementAnchor,
                    bubble: bubbleSize,
                    screen: safeBounds,
                    gap: gap
                )
            }
            let bubbleOrigin = if let canvasPlacement {
                canvasPlacement.origin
            } else {
                calloutOrigin(
                    placement: placement,
                    anchor: placementAnchor,
                    bubble: bubbleSize,
                    screen: safeBounds,
                    gap: gap
                )
            }

            ZStack(alignment: .topLeading) {
                // Background: spotlight scrim with cutout, or transparent tap-to-dismiss.
                if isSpotlight {
                    GuideSpotlightScrim(
                        anchorRect: anchorRect,
                        cutout: config.overlay.cutout,
                        cornerRadius: !isAnchorless
                            ? CGFloat(config.overlay.cutout.cornerRadius) * canvasScale
                            : cornerRadius,
                        isAnchorless: isAnchorless,
                        geometryScale: canvasScale,
                        color: guideColor(config.overlay.color, fallback: .black),
                        alpha: config.overlay.alpha
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isAnchorless {
                            if config.outsideTapBehavior == .next { onAdvance() }
                        } else if config.outsideTapBehavior == .next {
                            onOutsideTap()
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if config.outsideTapBehavior == .next { onOutsideTap() }
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
                            cornerRadius: !isAnchorless
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
                    resolvedCanvasScale: canvasPlacement?.scale,
                    canvasPointerDirection: arrowVisible ? placement.canvasPointerDirection : nil,
                    canvasPointerSize: arrowVisible ? arrowSize : 0,
                    canvasPointerCenter: arrowVisible
                        ? (placement.isVertical ? placementAnchor.midX - bubbleOrigin.x : placementAnchor.midY - bubbleOrigin.y)
                        : nil
                )
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
                onOutsideTap()
            }
        }
    }

    @ViewBuilder
    private func positionedBubble(
        viewportSize: CGSize,
        availableSize: CGSize,
        origin: CGPoint,
        resolvedCanvasScale: CGFloat?,
        canvasPointerDirection: GuideCanvasPointerDirection?,
        canvasPointerSize: CGFloat,
        canvasPointerCenter: CGFloat?
    ) -> some View {
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
        }
    }

    private func handleCanvasAction(_ request: CampaignCanvasActionRequest) {
        let reportedAction = request.actions.first?.resolved(with: variables)
        SDKInstance.shared.reportGuideStepClicked(
            actionType: reportedAction?.analyticsType,
            actionUrl: reportedAction?.analyticsURL,
            ctaLabel: request.label ?? request.elementId,
            action: reportedAction,
            elementId: request.elementId,
            isPrimary: request.isPrimary
        )
        Task {
            await SDKInstance.shared.executeActionFlow(
                guideActions(request.actions),
                variables: variables,
                localActionExecutor: LocalActionExecutor(
                    dismiss: {
                        guard SDKInstance.shared.guideOrchestrator.state?.token == guideToken else { return }
                        onDismiss()
                    },
                    next: {
                        guard SDKInstance.shared.guideOrchestrator.state?.token == guideToken else { return }
                        onAdvance()
                    },
                    previous: {
                        guard SDKInstance.shared.guideOrchestrator.state?.token == guideToken else { return }
                        SDKInstance.shared.previousGuide()
                    }
                )
            )
        }
    }

    private func guideActions(_ actions: [EngageAction]) -> [EngageAction] {
        var result: [EngageAction] = []
        for (index, action) in actions.enumerated() {
            result.append(action)
            if isLinkAction(action), actions.indices.contains(index + 1), actions[index + 1] == .dismiss {
                continue
            }
            if isLinkAction(action) { result.append(.dismiss) }
        }
        return result
    }

    private func isLinkAction(_ action: EngageAction) -> Bool {
        switch action {
        case .openUrl, .openDeeplink:
            return true
        default:
            return false
        }
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

private enum CalloutPlacement {
    case above
    case below
    case left
    case right

    init(preferred: String) {
        self = switch preferred {
        case "above", "top": .above
        case "below", "bottom": .below
        case "left", "start": .left
        case "right", "end": .right
        default: .below
        }
    }

    var isVertical: Bool { self == .above || self == .below }

    var canvasPointerDirection: GuideCanvasPointerDirection {
        switch self {
        case .above: return .down
        case .below: return .up
        case .left: return .right
        case .right: return .left
        }
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
    let requested = CalloutPlacement(preferred: preferred)
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

private struct GuideSpotlightScrim: View {
    let anchorRect: CGRect
    let cutout: CutoutConfig
    let cornerRadius: CGFloat
    let isAnchorless: Bool
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
            let path = shape.path(in: hole)
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
