import SwiftUI
import Combine

// Native multi-step guide renderer (tooltip / spotlight), ported from Android's
// `GuideRenderer.kt`. Driven by GuideOrchestrator state and styled entirely from
// GuideStepWidgetConfig (no SDUI viewId), positioned against a registered anchor.
@MainActor
struct GuideOverlayView: View {
    @ObservedObject private var orchestrator = SDKInstance.shared.guideOrchestrator
    @ObservedObject private var anchors = AnchorRegistry.shared
    @StateObject private var semanticSessions = SemanticTargetSessionStore()

    var body: some View {
        if let state = orchestrator.state,
           let step = state.currentStep {
            TimelineView(.animation) { _ in
                if let anchorRect = resolveRect(step) {
                    GuideStepOverlay(
                        step: step,
                        stepIndex: state.stepIndex,
                        totalSteps: state.steps.count,
                        anchorRect: anchorRect,
                        cornerRadius: step.semanticTarget == nil
                            && step.geometryTarget == nil
                            && step.assistedStepId == nil
                            ? AnchorRegistry.shared.getCornerRadius(for: step.anchorKey)
                            : CGFloat(step.widgetConfig.overlay.cutout.cornerRadius),
                        onAdvance: { orchestrator.advance() },
                        onDismiss: { SDKInstance.shared.dismissGuide() }
                    )
                    .environment(\.digiaVariables, state.variableContext)
                    .id(state.stepIndex)
                    .onAppear { SDKInstance.shared.reportNativeGuideStepVisible() }
                }
            }
        }
    }

    private func resolveRect(_ step: GuideStepModel) -> CGRect? {
        if let stepId = step.assistedStepId,
           let campaign = orchestrator.state?.campaign.guideConfig?.assistedCampaign,
           let window = keyWindow() {
            let snapshot = runtimeSnapshot(window)
            switch AssistedGeometryRuntimeV1.resolve(campaign, stepId: stepId, snapshot: snapshot) {
            case .resolved(_, _, let overlay, let warnings, let trace):
                if !warnings.isEmpty {
                    DigiaLog.warning(
                        "[AssistedGeometry] resolved with warnings: \(warnings.map(\.rawValue).joined(separator: ",")) variantId=\(trace.variantId ?? "")"
                    )
                }
                return CGRect(
                    x: overlay.left,
                    y: overlay.top,
                    width: overlay.width,
                    height: overlay.height
                )
            case .failed(let failure, let trace):
                DigiaLog.warning(
                    "[AssistedGeometry] resolution failed: \(failure.rawValue) variantId=\(trace.variantId ?? "")"
                )
                reportTargetFailure(
                    failure == .pageMismatch ? .noMatchingScreen : .renderError,
                    message: "Assisted Geometry failed: \(failure.rawValue)"
                )
                return nil
            }
        }
        if step.assistedStepId != nil {
            reportTargetFailure(.renderError, message: "Assisted Geometry host window is unavailable")
            return nil
        }
        if let geometryTarget = step.geometryTarget {
            guard geometryTarget.pageKey == SDKInstance.shared.currentScreen else {
                reportTargetFailure(.noMatchingScreen, message: "Typed Geometry page does not match")
                return nil
            }
            guard let window = keyWindow() else {
                reportTargetFailure(.renderError, message: "Typed Geometry host window is unavailable")
                return nil
            }
            if let rect = geometryTarget.resolve(snapshot: runtimeSnapshot(window)) {
                return rect
            }
            reportTargetFailure(.renderError, message: "Typed Geometry target could not be resolved")
            return nil
        }
        guard let target = step.semanticTarget else {
            return AnchorRegistry.shared.getRect(for: step.anchorKey)
        }
        guard let window = keyWindow() else { return nil }
        if case let .resolved(rect) = semanticSessions.resolve(
            stepId: step.id,
            root: window,
            currentPageKey: SDKInstance.shared.currentScreen,
            target: target
        ) {
            return rect
        }
        reportTargetFailure(.noMatchingScreen, message: "semantic target was not found on this screen")
        return nil
    }

    private func reportTargetFailure(_ code: LiveTestFailureCode, message: String) {
        Task { @MainActor in
            SDKInstance.shared.reportNativeGuideTargetFailure(code, message: message)
        }
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private func runtimeSnapshot(_ window: UIWindow) -> RuntimeGeometrySnapshotV1 {
        let scale = Double(window.screen.scale)
        let bounds = window.bounds
        let contentView = window.rootViewController?.view ?? window
        let contentBounds = contentView.convert(contentView.bounds, to: window)
        let direction = UIView.userInterfaceLayoutDirection(for: window.semanticContentAttribute)
        return RuntimeGeometrySnapshotV1(
            snapshotVersion: 1,
            platform: .ios,
            pageKey: SDKInstance.shared.currentScreen,
            density: scale,
            windowBoundsPx: EdgeRectV1(
                left: 0,
                top: 0,
                right: Double(bounds.width) * scale,
                bottom: Double(bounds.height) * scale
            ),
            appContentBoundsPx: EdgeRectV1(
                left: Double(contentBounds.minX) * scale,
                top: Double(contentBounds.minY) * scale,
                right: Double(contentBounds.maxX) * scale,
                bottom: Double(contentBounds.maxY) * scale
            ),
            layoutDirection: direction == .rightToLeft ? "rtl" : "ltr",
            orientation: bounds.height >= bounds.width ? "portrait" : "landscape",
            formFactor: UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "tablet",
            appIdentifier: Bundle.main.bundleIdentifier ?? "",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            locale: Locale.current.identifier,
            fontScale: Double(UIFontMetrics.default.scaledValue(for: 1))
        )
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
                                // Old-value param is unused, so the single-value overload
                                // (available since iOS 14, unlike the two-param one) works as-is.
                                .onChange(of: g.size.height) { newValue in bubbleHeight = newValue }
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
            let path = cutout.shape == "rect"
                ? Path(hole)
                : Path(roundedRect: hole, cornerRadius: radius)
            var clearContext = context
            clearContext.blendMode = .clear
            clearContext.fill(path, with: .color(.black))

            if cutout.glowWidth > 0 {
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addPath(path)
                var glowContext = context
                glowContext.clip(to: outside, style: FillStyle(eoFill: true))
                glowContext.addFilter(.blur(radius: 1.5))
                glowContext.stroke(
                    path,
                    with: .color(guideColor(cutout.glowColor, fallback: .clear)),
                    lineWidth: CGFloat(cutout.glowWidth)
                )
                var strokeContext = context
                strokeContext.clip(to: outside, style: FillStyle(eoFill: true))
                strokeContext.stroke(
                    path,
                    with: .color(guideColor(cutout.glowColor, fallback: .clear)),
                    lineWidth: CGFloat(cutout.glowWidth)
                )
            }
        }
    }
}

private func guideColor(_ hex: String, fallback: Color) -> Color {
    Color(hex: hex) ?? fallback
}
