import SwiftUI

private let canvasSurveySceneTransitionDuration: TimeInterval = 0.32

@MainActor
struct CanvasSurveyPanel: View {
    @ObservedObject var vm: SurveyViewModel
    let survey: SurveyConfigModel
    let canvasSurvey: CanvasSurveyConfig
    let accent: Color
    let onClose: () -> Void
    let onCompletedClose: () -> Void
    let showCloseButton: Bool
    let paintBackground: Bool
    @Binding var welcomeDone: Bool

    @State private var remainingSecs = 0
    @State private var autoAdvanceTask: Task<Void, Never>?
    @State private var timerTask: Task<Void, Never>?
    @State private var lastAutoAdvanceKey = ""
    @State private var completionReported = false
    @State private var validationError: String?
    @State private var activeFrame: CanvasSurveyFrame?
    @State private var previousFrame: CanvasSurveyFrame?
    @StateObject private var sceneTransition = CanvasSurveyTransitionClock()
    @Environment(\.digiaVariables) private var variables

    var body: some View {
        Group {
            if let frame = activeFrame ?? currentFrame {
                CanvasSurveyScaledStage(
                    frame: frame,
                    previousFrame: previousFrame,
                    transitionProgress: sceneTransition.progress,
                    survey: survey,
                    designWidth: canvasSurvey.designWidth,
                    vm: vm,
                    accent: accent,
                    remainingSecs: remainingSecs,
                    showCloseButton: showCloseButton,
                    paintBackground: paintBackground,
                    validationError: validationError,
                    onPrimary: primary,
                    onPrevious: previous,
                    onClose: onClose,
                    onCanvasAction: handleCanvasAction,
                    onValidationError: { message in
                        validationError = message
                    }
                )
            } else {
                EmptyView()
            }
        }
        .onAppear {
            syncSceneTransition(to: currentFrame, animated: false)
            remainingSecs = survey.settings.timer.timeLimitSeconds
            startTimerIfNeeded()
            reportQuestionViewedIfNeeded()
            scheduleAutoAdvanceIfNeeded()
        }
        .onChange(of: currentFrame?.key) { _ in
            syncSceneTransition(to: currentFrame, animated: true)
        }
        .onChange(of: vm.currentNodeId) { _ in
            clearValidationError()
            startTimerIfNeeded()
            reportQuestionViewedIfNeeded()
            scheduleAutoAdvanceIfNeeded()
        }
        .onChange(of: welcomeDone) { _ in
            reportQuestionViewedIfNeeded()
            scheduleAutoAdvanceIfNeeded()
        }
        .onChange(of: currentAnswer) { _ in
            if validationError != nil {
                validationError = vm.canvasValidationError()
            }
            scheduleAutoAdvanceIfNeeded()
        }
        .onDisappear {
            sceneTransition.stop()
            performWithoutAnimation { previousFrame = nil }
        }
    }

    private var showingWelcome: Bool {
        canvasSurvey.welcomeDocument != nil && !welcomeDone
    }

    private var currentNode: SurveyNode? {
        showingWelcome ? nil : vm.currentNode
    }

    private var currentBlock: SurveyBlock? {
        showingWelcome ? nil : vm.currentBlock
    }

    private var currentAnswer: SurveyAnswer? {
        currentNode.flatMap { vm.answers[$0.id] }
    }

    private var currentDocument: CanvasSurveyDocument? {
        if showingWelcome { return canvasSurvey.welcomeDocument }
        return currentSceneDocument.map {
            CanvasSurveyDocument(
                canvas: $0.canvas,
                sharedUi: $0.sharedUi,
                canvasHosts: $0.canvasHosts,
                sharedUiHosts: $0.sharedUiHosts
            )
        }
    }

    private var currentSceneDocument: CanvasSurveySceneDocument? {
        guard !showingWelcome, let node = vm.currentNode else { return nil }
        return canvasSurvey.document(for: node)
    }

    private var currentFrame: CanvasSurveyFrame? {
        guard let document = currentDocument else { return nil }
        return CanvasSurveyFrame(
            key: showingWelcome ? "canvas-survey-welcome" : "canvas-survey-node:\(currentNode?.id ?? "")",
            document: document,
            scene: showingWelcome ? nil : currentSceneDocument,
            block: currentBlock,
            answerNodeId: currentNode?.id
        )
    }

    private func syncSceneTransition(to nextFrame: CanvasSurveyFrame?, animated: Bool) {
        guard let nextFrame else {
            sceneTransition.stop()
            performWithoutAnimation {
                activeFrame = nil
                previousFrame = nil
            }
            return
        }
        guard activeFrame?.key != nextFrame.key else {
            performWithoutAnimation { activeFrame = nextFrame }
            return
        }
        sceneTransition.stop()
        let outgoingFrame = activeFrame
        performWithoutAnimation {
            previousFrame = outgoingFrame
            activeFrame = nextFrame
        }
        guard animated, previousFrame != nil else {
            performWithoutAnimation {
                previousFrame = nil
            }
            return
        }
        sceneTransition.start {
            if activeFrame?.key == nextFrame.key {
                performWithoutAnimation {
                    previousFrame = nil
                }
            }
        }
    }

    private func performWithoutAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    private func primary() {
        if showingWelcome {
            SDKInstance.shared.reportSurveyWelcomeStart()
            SDKInstance.shared.reportSurveyStartClicked()
            welcomeDone = true
            return
        }
        guard let node = vm.currentNode, let block = vm.currentBlock else { return }
        if block.type == .resultPage {
            onCompletedClose()
            return
        }
        guard vm.canAdvance() else {
            validationError = vm.canvasValidationError()
            return
        }
        clearValidationError()
        if !block.type.isContent {
            if let ans = vm.answers[node.id], ans.isAnswered {
                SDKInstance.shared.reportSurveyAnswered(stepId: node.id, answer: ans.toMap())
            } else if !block.required {
                SDKInstance.shared.reportSurveyQuestionSkipped(
                    nodeId: node.id, itemIndex: vm.currentItemIndex)
            }
        }
        reportCompletionIfResultIsNext()
        vm.advance()
    }

    private func previous() {
        if !showingWelcome && vm.canGoBack {
            vm.back()
        }
        clearValidationError()
    }

    private func clearValidationError() {
        validationError = nil
    }

    private func handleCanvasAction(_ request: CampaignCanvasActionRequest) {
        Task { @MainActor in
            await SDKInstance.shared.executeActionFlow(
                request.actions,
                variables: variables,
                localActionExecutor: LocalActionExecutor(
                    dismiss: onClose,
                    next: primary,
                    previous: previous
                )
            )
        }
    }

    private func reportQuestionViewedIfNeeded() {
        guard !showingWelcome, let node = vm.currentNode, let block = vm.currentBlock,
            !block.type.isContent
        else {
            return
        }
        SDKInstance.shared.reportSurveyQuestionViewed(
            nodeId: node.id, itemIndex: vm.currentItemIndex)
    }

    private func scheduleAutoAdvanceIfNeeded() {
        guard !showingWelcome, let node = vm.currentNode else { return }
        guard vm.shouldAutoAdvance() else { return }
        guard let ans = vm.answers[node.id], ans.isAnswered else { return }
        let key = "\(node.id):\(ans.values.joined(separator: ","))"
        guard key != lastAutoAdvanceKey else { return }
        lastAutoAdvanceKey = key
        autoAdvanceTask?.cancel()
        autoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            guard vm.currentNode?.id == node.id else { return }
            SDKInstance.shared.reportSurveyAnswered(stepId: node.id, answer: ans.toMap())
            reportCompletionIfResultIsNext()
            vm.advance()
        }
    }

    private func reportCompletionIfResultIsNext() {
        if !completionReported && vm.nextBlockIsResultPage() {
            SDKInstance.shared.reportSurveyCompleted(
                response: vm.responsePayload(), answers: vm.answers)
            completionReported = true
        }
    }

    private func startTimerIfNeeded() {
        let timer = survey.settings.timer
        guard timer.enabled && timer.timeLimitSeconds > 0 else { return }
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while remainingSecs > 0 {
                if Task.isCancelled { return }
                let paused = timer.pauseOnNonTimerBlock && (vm.currentBlock?.type.isContent == true)
                try? await Task.sleep(nanoseconds: paused ? 500_000_000 : 1_000_000_000)
                if Task.isCancelled { return }
                if !paused { remainingSecs = max(0, remainingSecs - 1) }
            }
            if remainingSecs == 0 { onClose() }
        }
    }
}

// Recompute the fade and layout curves from elapsed time on every display frame.
// Animating a plain @State Double only interpolates the resulting view properties.
@MainActor
private final class CanvasSurveyTransitionClock: NSObject, ObservableObject {
    @Published private(set) var progress = 1.0
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var completion: (() -> Void)?

    func start(completion: @escaping () -> Void) {
        stop()
        self.completion = completion
        startedAt = CACurrentMediaTime()
        updateProgress(0)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        completion = nil
        updateProgress(1)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = max(0, link.timestamp - startedAt)
        let value = min(1, elapsed / canvasSurveySceneTransitionDuration)
        updateProgress(value)
        if value >= 1 {
            let completed = completion
            stop()
            completed?()
        }
    }

    private func updateProgress(_ value: Double) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { progress = value }
    }
}

private struct CanvasSurveyFrame {
    let key: String
    let document: CanvasSurveyDocument
    let scene: CanvasSurveySceneDocument?
    let block: SurveyBlock?
    let answerNodeId: String?
}

private struct CanvasSurveyScaledStage: View {
    let frame: CanvasSurveyFrame
    let previousFrame: CanvasSurveyFrame?
    let transitionProgress: Double
    let survey: SurveyConfigModel
    let designWidth: CGFloat
    @ObservedObject var vm: SurveyViewModel
    let accent: Color
    let remainingSecs: Int
    let showCloseButton: Bool
    let paintBackground: Bool
    let validationError: String?
    let onPrimary: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onCanvasAction: (CampaignCanvasActionRequest) -> Void
    let onValidationError: (String?) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.canvasSurveyDialogPresentation) private var dialogPresentation

    var body: some View {
        if let dialog = dialogPresentation {
            // Fit once against the full window, as Android does inside its
            // vertically unbounded scroll content. IME height never affects scale.
            let scale = canvasSurveyFitScale(
                designScale: canvasSurveyDesignScale(viewportWidth: dialog.viewport.width),
                availableWidth: dialog.availableWidth,
                availableHeight: dialog.viewport.height
            )
            scaledStage(scale: scale)
                .modifier(CanvasSurveyDialogKeyboardLayout(
                    presentation: dialog,
                    surfaceSize: CGSize(width: stageWidth * scale, height: stageHeight * scale),
                    onClose: onClose,
                    keyboardInset: dialog.keyboardInset
                ))
                .animation(dialog.animation, value: dialog.keyboardInset)
                // SurveySession disables cover presentation animations. Permit
                // this dialog's inset interpolation; its children opt out inside.
                .transaction { $0.disablesAnimations = false }
        } else {
            GeometryReader { geo in
                let scale = canvasSurveyFitScale(
                    designScale: canvasSurveyDesignScale(viewportWidth: UIScreen.main.bounds.width),
                    availableWidth: geo.size.width,
                    availableHeight: geo.size.height > 0 ? geo.size.height : UIScreen.main.bounds.height
                )
                scaledStage(scale: scale)
            }
            .aspectRatio(stageWidth / max(1, stageHeight), contentMode: .fit)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scaledStage(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if paintBackground {
                CampaignCanvasBackgroundView(paint: document.sharedUi.background)
                    .frame(width: stageWidth, height: stageHeight)
                    .allowsHitTesting(false)
            }
            CanvasSurveyContentLayer(
                frame: frame,
                previousFrame: previousFrame,
                transitionProgress: transitionProgress,
                survey: survey,
                vm: vm,
                accent: accent,
                onCanvasAction: onCanvasAction,
                onValidationError: onValidationError
            )
            .frame(width: stageWidth, height: stageHeight, alignment: .topLeading)
            .clipped()
            CampaignCanvasStage(
                canvas: document.sharedUi,
                authoredCornerRadius: 0,
                isDark: CampaignCanvasTheme.shared.isDark(colorScheme),
                showBackground: false,
                onAction: onCanvasAction,
                backgroundTakesTouches: false,
                animateWidgetsOnAppear: false
            )
            ForEach(managedHosts, id: \.id) { host in
                CanvasSurveyHostView(
                    host: .managed(host),
                    scene: frame.scene,
                    survey: survey,
                    block: frame.block,
                    answerNodeId: frame.answerNodeId,
                    vm: vm,
                    accent: accent,
                    remainingSecs: remainingSecs,
                    showCloseButton: showCloseButton,
                    onPrimary: onPrimary,
                    onPrevious: onPrevious,
                    onClose: onClose,
                    onCanvasAction: onCanvasAction,
                    onValidationError: onValidationError
                )
                .frame(width: host.rect.width, height: host.rect.height, alignment: .topLeading)
                .offset(x: host.rect.x, y: host.rect.y)
            }
            if let validationError, !validationError.isEmpty, let rect = validationErrorRect {
                CanvasSurveyValidationErrorView(message: validationError)
                    .frame(width: rect.width, alignment: .center)
                    .offset(x: rect.x, y: rect.y)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: stageWidth, height: stageHeight, alignment: .topLeading)
        .clipped()
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: stageWidth * scale, height: stageHeight * scale, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if showCloseButton, let canvasConfig = survey.canvasSurvey,
               let close = canvasConfig.closeButton, close.placement?.rect != nil {
                let size = CGSize(width: stageWidth * scale, height: stageHeight * scale)
                CanvasNudgeCloseOverlay(
                    config: mappedClose(close, source: canvasConfig.closeCanvasSize),
                    container: CGRect(origin: .zero, size: size),
                    viewport: size, safeAreaInsets: .zero,
                    isBottomSheet: survey.settings.display.type == .bottomSheet,
                    action: onClose)
            }
        }
    }

    private var document: CanvasSurveyDocument {
        visualDocument
    }

    private var visualDocument: CanvasSurveyDocument {
        canvasSurveyVisualDocument(
            current: frame.document,
            previous: previousFrame?.document,
            progress: transitionProgress
        )
    }

    private func mappedClose(_ close: NudgeCloseButtonConfig, source: CGSize) -> NudgeCloseButtonConfig {
        var result = close
        result.placement = close.placement?.forCanvas(
            source: source, target: CGSize(width: stageWidth, height: stageHeight))
        return result
    }

    private var managedHosts: [CanvasSurveyManagedHostElement] {
        let hosts = document.canvasHosts.compactMap { host in
            if case .managed(let managedHost) = host { return managedHost }
            return nil
        } + document.sharedUiHosts
        return hosts
    }

    private var stageWidth: CGFloat {
        max(document.canvas.width, document.sharedUi.width, 1)
    }

    private var stageHeight: CGFloat {
        max(document.canvas.height, 1)
    }

    private var validationErrorRect: CampaignCanvasRect? {
        let answerRect = document.canvasHosts.compactMap { host -> CampaignCanvasRect? in
            if case .answer(let answerHost) = host { return answerHost.rect }
            return nil
        }.first
        if let answerRect {
            return CampaignCanvasRect(
                x: answerRect.x,
                y: answerRect.y + answerRect.height + 2,
                width: answerRect.width,
                height: 24
            )
        }
        let margin: CGFloat = 8
        let labelHeight: CGFloat = 32
        let maxWidth = max(margin, stageWidth - margin * 2)
        let width = min(maxWidth, max(answerRect?.width ?? maxWidth, 180))
        let sourceX = answerRect?.x ?? margin
        let sourceY = answerRect?.y ?? margin
        let sourceWidth = answerRect?.width ?? width
        let maxLeft = max(margin, stageWidth - width - margin)
        let left = min(max(sourceX + (sourceWidth - width) / 2, margin), maxLeft)
        let maxTop = max(margin, stageHeight - labelHeight - margin)
        let top = min(max(sourceY + (answerRect?.height ?? 0) + 8, margin), maxTop)
        return CampaignCanvasRect(x: left, y: top, width: width, height: labelHeight)
    }

    private func canvasSurveyDesignScale(viewportWidth: CGFloat) -> CGFloat {
        let base = viewportWidth / max(1, designWidth)
        return survey.settings.display.type == .bottomSheet ? base : min(1.15, base)
    }

    private func canvasSurveyFitScale(
        designScale: CGFloat,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        let desiredWidth = stageWidth * designScale
        let desiredHeight = stageHeight * designScale
        let widthFit = desiredWidth > 0 ? availableWidth / desiredWidth : 1
        let heightFit = desiredHeight > 0 ? availableHeight / desiredHeight : 1
        return designScale * min(1, widthFit, heightFit)
    }
}

private func canvasSurveyVisualDocument(
    current: CanvasSurveyDocument,
    previous: CanvasSurveyDocument?,
    progress: Double
) -> CanvasSurveyDocument {
    guard let previous else { return current }
    let eased = easeInOutCubic(CGFloat(min(1, max(0, progress))))
    let previousWidth = max(previous.canvas.width, previous.sharedUi.width)
    let currentWidth = max(current.canvas.width, current.sharedUi.width)
    let visualWidth = max(1, lerp(previousWidth, currentWidth, eased))
    let visualHeight = max(1, lerp(previous.canvas.height, current.canvas.height, eased))
    let previousSharedChildren = Dictionary(
        previous.sharedUi.children.map { ($0.id, $0) },
        uniquingKeysWith: { _, last in last }
    )
    let previousManagedHosts = Dictionary(
        (
            previous.canvasHosts.compactMap { host -> CanvasSurveyManagedHostElement? in
                if case .managed(let managedHost) = host { return managedHost }
                return nil
            } + previous.sharedUiHosts
        ).map { ($0.id, $0) },
        uniquingKeysWith: { _, last in last }
    )
    return CanvasSurveyDocument(
        canvas: CampaignCanvas(
            version: current.canvas.version,
            width: visualWidth,
            height: visualHeight,
            background: current.canvas.background,
            children: current.canvas.children
        ),
        sharedUi: CampaignCanvas(
            version: current.sharedUi.version,
            width: visualWidth,
            height: visualHeight,
            background: current.sharedUi.background,
            children: current.sharedUi.children.map { child in
                child.withRect(
                    lerpRect(
                        previousSharedChildren[child.id]?.rect ?? child.rect,
                        child.rect,
                        eased
                    )
                )
            }
        ),
        canvasHosts: current.canvasHosts.map { host in
            guard case .managed(let managedHost) = host else { return host }
            return .managed(
                managedHost.withRect(
                    lerpRect(
                        previousManagedHosts[managedHost.id]?.rect ?? managedHost.rect,
                        managedHost.rect,
                        eased
                    )
                )
            )
        },
        sharedUiHosts: current.sharedUiHosts.map { host in
            return host.withRect(
                lerpRect(
                    previousManagedHosts[host.id]?.rect ?? host.rect,
                    host.rect,
                    eased
                )
            )
        }
    )
}

private func easeInOutCubic(_ value: CGFloat) -> CGFloat {
    if value < 0.5 {
        return 4 * value * value * value
    }
    let shifted = -2 * value + 2
    return 1 - shifted * shifted * shifted / 2
}

private func canvasSurveyOutgoingAlpha(_ progress: Double) -> Double {
    let phase = min(1, max(0, progress / 0.4))
    return 1 - Double(easeOutCubic(CGFloat(phase)))
}

private func canvasSurveyIncomingAlpha(_ progress: Double) -> Double {
    let phase = min(1, max(0, (progress - 0.18) / 0.82))
    return Double(easeOutCubic(CGFloat(phase)))
}

private func easeOutCubic(_ value: CGFloat) -> CGFloat {
    let inverted = 1 - value
    return 1 - inverted * inverted * inverted
}

private func lerpRect(
    _ begin: CampaignCanvasRect,
    _ end: CampaignCanvasRect,
    _ progress: CGFloat
) -> CampaignCanvasRect {
    CampaignCanvasRect(
        x: lerp(begin.x, end.x, progress),
        y: lerp(begin.y, end.y, progress),
        width: lerp(begin.width, end.width, progress),
        height: lerp(begin.height, end.height, progress)
    )
}

private func lerp(_ begin: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
    begin + (end - begin) * progress
}

private extension CampaignCanvasChild {
    func withRect(_ rect: CampaignCanvasRect) -> CampaignCanvasChild {
        switch self {
        case .widget(let id, _, let widget):
            return .widget(id: id, rect: rect, widget: widget)
        case .tapRegion(let id, _, let actions, let isPrimary):
            return .tapRegion(id: id, rect: rect, actions: actions, isPrimary: isPrimary)
        }
    }
}

private extension CanvasSurveyManagedHostElement {
    func withRect(_ rect: CampaignCanvasRect) -> CanvasSurveyManagedHostElement {
        CanvasSurveyManagedHostElement(
            id: id,
            rect: rect,
            role: role,
            visible: visible,
            label: label,
            doneLabel: doneLabel,
            colorHex: colorHex,
            fillHex: fillHex,
            trackColorHex: trackColorHex,
            borderColorHex: borderColorHex,
            borderWidth: borderWidth,
            cornerRadius: cornerRadius,
            fontSize: fontSize,
            gap: gap,
            padding: padding,
            progressStyle: progressStyle,
            countQuestionsOnly: countQuestionsOnly,
            button: button
        )
    }
}

private struct CanvasSurveyContentLayer: View {
    let frame: CanvasSurveyFrame
    let previousFrame: CanvasSurveyFrame?
    let transitionProgress: Double
    let survey: SurveyConfigModel
    @ObservedObject var vm: SurveyViewModel
    let accent: Color
    let onCanvasAction: (CampaignCanvasActionRequest) -> Void
    let onValidationError: (String?) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(contentFrames, id: \.key) { contentFrame in
                let incoming = contentFrame.key == frame.key
                CanvasSurveyContentFrame(
                    frame: contentFrame,
                    answerInteractive: incoming,
                    survey: survey,
                    vm: vm,
                    accent: accent,
                    onCanvasAction: onCanvasAction,
                    onValidationError: onValidationError
                )
                .compositingGroup()
                .opacity(previousFrame == nil ? 1 : incoming
                    ? canvasSurveyIncomingAlpha(transitionProgress)
                    : canvasSurveyOutgoingAlpha(transitionProgress))
                .transition(.identity)
                .allowsHitTesting(incoming)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var contentFrames: [CanvasSurveyFrame] {
        if let previousFrame { return [previousFrame, frame] }
        return [frame]
    }
}

private struct CanvasSurveyContentFrame: View {
    let frame: CanvasSurveyFrame
    let answerInteractive: Bool
    let survey: SurveyConfigModel
    @ObservedObject var vm: SurveyViewModel
    let accent: Color
    let onCanvasAction: (CampaignCanvasActionRequest) -> Void
    let onValidationError: (String?) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            CampaignCanvasStage(
                canvas: frame.document.canvas,
                authoredCornerRadius: 0,
                isDark: CampaignCanvasTheme.shared.isDark(colorScheme),
                showBackground: false,
                onAction: onCanvasAction
            )
            ForEach(answerHosts, id: \.id) { host in
                CanvasSurveyHostView(
                    host: .answer(host),
                    scene: frame.scene,
                    survey: survey,
                    block: frame.block,
                    answerNodeId: frame.answerNodeId,
                    vm: vm,
                    accent: accent,
                    remainingSecs: 0,
                    showCloseButton: false,
                    onPrimary: {},
                    onPrevious: {},
                    onClose: {},
                    onCanvasAction: onCanvasAction,
                    onValidationError: answerInteractive ? onValidationError : { _ in }
                )
                .frame(width: host.rect.width, height: host.rect.height, alignment: .topLeading)
                .offset(x: host.rect.x, y: host.rect.y)
                .allowsHitTesting(answerInteractive)
            }
        }
        .frame(
            width: max(frame.document.canvas.width, frame.document.sharedUi.width, 1),
            height: max(frame.document.canvas.height, 1),
            alignment: .topLeading
        )
        .clipped()
        .allowsHitTesting(answerInteractive)
    }

    private var answerHosts: [CanvasSurveyAnswerHostElement] {
        frame.document.canvasHosts.compactMap { host in
            if case .answer(let answerHost) = host { return answerHost }
            return nil
        }
    }
}

private struct CanvasSurveyValidationErrorView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(surveyFont(size: 12, weight: 600))
            .foregroundColor(Color(red: 0.85, green: 0.18, blue: 0.13))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(red: 0.85, green: 0.18, blue: 0.13), lineWidth: 1)
            )
    }
}

private struct CanvasSurveyHostView: View {
    let host: CanvasSurveyHostElement
    let scene: CanvasSurveySceneDocument?
    let survey: SurveyConfigModel
    let block: SurveyBlock?
    let answerNodeId: String?
    @ObservedObject var vm: SurveyViewModel
    let accent: Color
    let remainingSecs: Int
    let showCloseButton: Bool
    let onPrimary: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onCanvasAction: (CampaignCanvasActionRequest) -> Void
    let onValidationError: (String?) -> Void

    var body: some View {
        switch host {
        case .answer(let host):
            if let scene, let block, let answerNodeId, !block.type.isContent {
                CanvasSurveyAnswerInputView(
                    scene: scene,
                    host: host,
                    answer: vm.answers[answerNodeId],
                    onAnswer: {
                        vm.setAnswer(answerNodeId, $0)
                        onValidationError(vm.canvasValidationError())
                    },
                    onValidationError: onValidationError
                )
            }
        case .managed(let host):
            CanvasSurveyManagedHostView(
                host: host,
                survey: survey,
                block: block,
                vm: vm,
                accent: accent,
                remainingSecs: remainingSecs,
                showCloseButton: showCloseButton,
                onPrimary: onPrimary,
                onPrevious: onPrevious,
                onClose: onClose,
                onCanvasAction: onCanvasAction
            )
        }
    }
}

private struct CanvasSurveyManagedHostView: View {
    let host: CanvasSurveyManagedHostElement
    let survey: SurveyConfigModel
    let block: SurveyBlock?
    @ObservedObject var vm: SurveyViewModel
    let accent: Color
    let remainingSecs: Int
    let showCloseButton: Bool
    let onPrimary: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onCanvasAction: (CampaignCanvasActionRequest) -> Void

    var body: some View {
        if host.visible {
            switch host.role {
            case .progress:
                CanvasSurveyProgressHost(
                    host: host,
                    progress: vm.progressFraction(countQuestionsOnly: host.countQuestionsOnly),
                    currentSegment: vm.progressCurrent(countQuestionsOnly: host.countQuestionsOnly),
                    totalSegments: vm.progressTotal(countQuestionsOnly: host.countQuestionsOnly)
                )
            case .pageCount:
                CanvasSurveyTextHost(
                    host: host,
                    text:
                        "\(vm.progressCurrent(countQuestionsOnly: host.countQuestionsOnly))/\(vm.progressTotal(countQuestionsOnly: host.countQuestionsOnly))"
                )
            case .timer:
                if survey.settings.timer.enabled && survey.settings.timer.timeLimitSeconds > 0 {
                    CanvasSurveyTextHost(host: host, text: formatRemaining(remainingSecs))
                }
            case .primaryNavigation:
                let isResult = block?.type == .resultPage
                let label =
                    isResult ? host.doneLabel.nonEmpty(or: "Done") : host.label.nonEmpty(or: "Next")
                CanvasSurveyButtonHost(
                    host: host,
                    text: label,
                    enabled: isResult || block == nil || vm.canAdvance(),
                    interactive: true,
                    accent: accent,
                    onClick: onPrimary
                )
            case .backNavigation:
                CanvasSurveyButtonHost(
                    host: host,
                    text: host.label.nonEmpty(or: "Back"),
                    enabled: vm.canGoBack,
                    interactive: vm.canGoBack,
                    accent: accent,
                    onClick: onPrevious
                )
            }
        }
    }
}

private struct CanvasSurveyProgressHost: View {
    let host: CanvasSurveyManagedHostElement
    let progress: Double
    let currentSegment: Int
    let totalSegments: Int

    var body: some View {
        let active = Color(hex: host.colorHex) ?? SurveyTokens.textPrimary
        let track = Color(hex: host.trackColorHex) ?? SurveyTokens.surfaceSunken
        if host.progressStyle == "segmented" && totalSegments > 1 {
            HStack(spacing: host.gap) {
                ForEach(1...totalSegments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: host.cornerRadius)
                        .fill(index <= currentSegment ? active : track)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: host.cornerRadius).fill(track)
                    RoundedRectangle(cornerRadius: host.cornerRadius)
                        .fill(active)
                        .frame(width: geo.size.width * min(1, max(0, progress)))
                }
            }
        }
    }
}

private struct CanvasSurveyButtonHost: View {
    let host: CanvasSurveyManagedHostElement
    let text: String
    let enabled: Bool
    var interactive = true
    let accent: Color
    let onClick: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let button = host.button {
            CampaignCanvasRendererRegistry.render(
                interactive ? button : button.withoutActions(),
                isDark: CampaignCanvasTheme.shared.isDark(colorScheme),
                onAction: { _ in if interactive { onClick() } }
            )
            .opacity(enabled ? 1 : 0.45)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        } else {
            let fill = Color(hex: host.fillHex) ?? accent
            let foreground = Color(hex: host.colorHex) ?? Color.white
            Button(action: onClick) {
                Text(text)
                    .font(surveyFont(size: host.fontSize, weight: 600))
                    .foregroundColor(foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: host.cornerRadius)
                            .fill(fill)
                    )
            }
            .opacity(enabled ? 1 : 0.45)
            .buttonStyle(.plain)
            .disabled(!interactive)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

extension CampaignCanvasWidget {
    fileprivate func withoutActions() -> CampaignCanvasWidget {
        guard
            case .button(
                let box,
                let label,
                let cornerRadius,
                let style,
                let shadow,
                let isPrimary,
                let isDestructive,
                let applyDestructiveStyling,
                _,
                let confirm
            ) = self
        else { return self }
        return .button(
            box: box,
            label: label,
            cornerRadius: cornerRadius,
            style: style,
            shadow: shadow,
            isPrimary: isPrimary,
            isDestructive: isDestructive,
            applyDestructiveStyling: applyDestructiveStyling,
            actions: [],
            confirm: confirm
        )
    }

}

private struct CanvasSurveyTextHost: View {
    let host: CanvasSurveyManagedHostElement
    let text: String

    var body: some View {
        Text(text)
            .font(surveyFont(size: host.fontSize, weight: 600))
            .foregroundColor(Color(hex: host.colorHex) ?? SurveyTokens.textSecondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(host.padding)
            .background(
                RoundedRectangle(cornerRadius: host.cornerRadius)
                    .fill(Color(hex: host.fillHex) ?? Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: host.cornerRadius)
                    .stroke(
                        Color(hex: host.borderColorHex) ?? Color.clear, lineWidth: host.borderWidth)
            )
    }
}

private func formatRemaining(_ remainingSecs: Int) -> String {
    String(format: "%d:%02d", remainingSecs / 60, remainingSecs % 60)
}

extension String {
    fileprivate func nonEmpty(or fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
