import SwiftUI

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

    var body: some View {
        Group {
            if let document = currentDocument {
                CanvasSurveyScaledStage(
                    document: document,
                    scene: currentSceneDocument,
                    survey: survey,
                    designWidth: canvasSurvey.designWidth,
                    block: currentBlock,
                    answerNodeId: currentNode?.id,
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
            remainingSecs = survey.settings.timer.timeLimitSeconds
            startTimerIfNeeded()
            reportQuestionViewedIfNeeded()
            scheduleAutoAdvanceIfNeeded()
        }
        .onChange(of: vm.currentNodeId) { _ in
            clearValidationError()
            startTimerIfNeeded()
            reportQuestionViewedIfNeeded()
            scheduleAutoAdvanceIfNeeded()
        }
        .onChange(of: currentAnswer) { _ in
            if validationError != nil {
                validationError = vm.canvasValidationError()
            }
            scheduleAutoAdvanceIfNeeded()
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

    private func primary() {
        if showingWelcome {
            SDKInstance.shared.reportSurveyWelcomeStart()
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
        if !showingWelcome && vm.canGoBack { vm.back() }
        clearValidationError()
    }

    private func clearValidationError() {
        validationError = nil
    }

    private func handleCanvasAction(_ request: CampaignCanvasActionRequest) {
        if request.actions.contains(.next) {
            primary()
        } else if request.actions.contains(.previous) {
            previous()
        } else if request.actions.contains(.dismiss) {
            onClose()
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

private struct CanvasSurveyScaledStage: View {
    let document: CanvasSurveyDocument
    let scene: CanvasSurveySceneDocument?
    let survey: SurveyConfigModel
    let designWidth: CGFloat
    let block: SurveyBlock?
    let answerNodeId: String?
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

    var body: some View {
        GeometryReader { geo in
            let designScale = canvasSurveyDesignScale(viewportWidth: UIScreen.main.bounds.width)
            let scale = canvasSurveyFitScale(
                designScale: designScale,
                availableWidth: geo.size.width,
                availableHeight: geo.size.height > 0 ? geo.size.height : UIScreen.main.bounds.height
            )
            ZStack(alignment: .topLeading) {
                if paintBackground {
                    CampaignCanvasBackgroundView(paint: document.sharedUi.background)
                        .frame(width: stageWidth, height: stageHeight)
                        .allowsHitTesting(false)
                }
                CampaignCanvasStage(
                    canvas: document.canvas,
                    authoredCornerRadius: 0,
                    isDark: CampaignCanvasTheme.shared.isDark(colorScheme),
                    showBackground: false,
                    onAction: onCanvasAction
                )
                CampaignCanvasStage(
                    canvas: document.sharedUi,
                    authoredCornerRadius: 0,
                    isDark: CampaignCanvasTheme.shared.isDark(colorScheme),
                    showBackground: false,
                    onAction: onCanvasAction,
                    backgroundTakesTouches: false
                )
                ForEach(Array(hosts.enumerated()), id: \.offset) { _, host in
                    CanvasSurveyHostView(
                        host: host,
                        scene: scene,
                        survey: survey,
                        block: block,
                        answerNodeId: answerNodeId,
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
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: stageWidth * scale, height: stageHeight * scale, alignment: .topLeading)
        }
        .aspectRatio(stageWidth / max(1, stageHeight), contentMode: .fit)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hosts: [CanvasSurveyHostElement] {
        document.canvasHosts + document.sharedUiHosts.map(CanvasSurveyHostElement.managed)
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
                if vm.canGoBack {
                    CanvasSurveyButtonHost(
                        host: host,
                        text: host.label.nonEmpty(or: "Back"),
                        enabled: true,
                        accent: accent,
                        onClick: onPrevious
                    )
                }
            case .dismiss:
                if showCloseButton {
                    CanvasSurveyDismissHost(
                        host: host, onClose: onClose, onCanvasAction: onCanvasAction)
                }
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
        }
    }
}

private struct CanvasSurveyDismissHost: View {
    let host: CanvasSurveyManagedHostElement
    let onClose: () -> Void
    let onCanvasAction: (CampaignCanvasActionRequest) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let button = host.button {
            ZStack {
                CampaignCanvasRendererRegistry.render(
                    button.withoutLabel(),
                    isDark: CampaignCanvasTheme.shared.isDark(colorScheme),
                    onAction: onCanvasAction
                )
                dismissIcon.allowsHitTesting(false)
            }
        } else {
            let fill = Color(hex: host.fillHex) ?? SurveyTokens.surface
            let border = Color(hex: host.borderColorHex)
            Button(action: onClose) {
                dismissIcon
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: host.cornerRadius)
                            .fill(fill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: host.cornerRadius)
                            .stroke(border ?? .clear, lineWidth: host.borderWidth)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var dismissIcon: some View {
        let iconSize = host.iconSize > 0 ? host.iconSize : 18
        return Image(systemName: "xmark")
            .font(surveyFont(size: iconSize * 0.72, weight: 600))
            .foregroundColor(
                host.iconColorHex.flatMap(Color.init(hex:))
                    ?? Color(hex: host.colorHex)
                    ?? SurveyTokens.textTertiary
            )
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

    fileprivate func withoutLabel() -> CampaignCanvasWidget {
        guard
            case .button(
                let box,
                var label,
                let cornerRadius,
                let style,
                let shadow,
                let isPrimary,
                let isDestructive,
                let applyDestructiveStyling,
                let actions,
                let confirm
            ) = self
        else { return self }
        label.spans = label.spans.map {
            CampaignCanvasTextSpan(
                text: "",
                typography: $0.typography,
                color: $0.color,
                highlightColor: $0.highlightColor,
                italic: $0.italic,
                decoration: $0.decoration,
                decorationColor: $0.decorationColor,
                decorationThickness: $0.decorationThickness,
                actions: $0.actions
            )
        }
        return .button(
            box: box,
            label: label,
            cornerRadius: cornerRadius,
            style: style,
            shadow: shadow,
            isPrimary: isPrimary,
            isDestructive: isDestructive,
            applyDestructiveStyling: applyDestructiveStyling,
            actions: actions,
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
