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

    @State private var welcomeDone = false
    @State private var remainingSecs = 0
    @State private var autoAdvanceTask: Task<Void, Never>?
    @State private var timerTask: Task<Void, Never>?
    @State private var lastAutoAdvanceKey = ""
    @State private var completionReported = false

    var body: some View {
        Group {
            if let document = currentDocument {
                CanvasSurveyScaledStage(
                    document: document,
                    survey: survey,
                    block: currentBlock,
                    answerNodeId: currentNode?.id,
                    vm: vm,
                    accent: accent,
                    remainingSecs: remainingSecs,
                    showCloseButton: showCloseButton,
                    onPrimary: primary,
                    onPrevious: previous,
                    onClose: onClose,
                    onCanvasAction: handleCanvasAction
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
            startTimerIfNeeded()
            reportQuestionViewedIfNeeded()
            scheduleAutoAdvanceIfNeeded()
        }
        .onChange(of: currentAnswer) { _ in
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
        guard let node = vm.currentNode, let scene = canvasSurvey.document(for: node) else { return nil }
        return CanvasSurveyDocument(
            canvas: scene.canvas,
            sharedUi: scene.sharedUi,
            canvasHosts: scene.canvasHosts,
            sharedUiHosts: scene.sharedUiHosts
        )
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
        guard vm.canAdvance() else { return }
        if !block.type.isContent {
            if let ans = vm.answers[node.id], ans.isAnswered {
                SDKInstance.shared.reportSurveyAnswered(stepId: node.id, answer: ans.toMap())
            } else if !block.required {
                SDKInstance.shared.reportSurveyQuestionSkipped(nodeId: node.id, itemIndex: vm.currentItemIndex)
            }
        }
        reportCompletionIfResultIsNext()
        vm.advance()
    }

    private func previous() {
        if !showingWelcome && vm.canGoBack { vm.back() }
    }

    private func handleCanvasAction(_ request: CampaignCanvasActionRequest) {
        if request.actions.contains(.next) {
            primary()
        } else if request.actions.contains(.previous) {
            previous()
        } else if request.actions.contains(.dismiss), survey.settings.display.dismissible {
            onClose()
        }
    }

    private func reportQuestionViewedIfNeeded() {
        guard !showingWelcome, let node = vm.currentNode, let block = vm.currentBlock, !block.type.isContent else {
            return
        }
        SDKInstance.shared.reportSurveyQuestionViewed(nodeId: node.id, itemIndex: vm.currentItemIndex)
    }

    private func scheduleAutoAdvanceIfNeeded() {
        guard !showingWelcome, let node = vm.currentNode, let block = vm.currentBlock else { return }
        guard survey.settings.autoAdvance && block.type.isAutoAdvanceCandidate else { return }
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
            SDKInstance.shared.reportSurveyCompleted(response: vm.responsePayload(), answers: vm.answers)
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / max(1, document.canvas.width)
            ZStack(alignment: .topLeading) {
                CampaignCanvasStage(
                    canvas: document.canvas,
                    authoredCornerRadius: 0,
                    isDark: CampaignCanvasTheme.shared.isDark(colorScheme),
                    showBackground: true,
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
                        survey: survey,
                        block: block,
                        answerNodeId: answerNodeId,
                        vm: vm,
                        accent: accent,
                        remainingSecs: remainingSecs,
                        showCloseButton: showCloseButton,
                        onPrimary: onPrimary,
                        onPrevious: onPrevious,
                        onClose: onClose
                    )
                    .frame(width: host.rect.width, height: host.rect.height, alignment: .topLeading)
                    .offset(x: host.rect.x, y: host.rect.y)
                }
            }
            .frame(width: document.canvas.width, height: document.canvas.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: geo.size.width, height: document.canvas.height * scale, alignment: .topLeading)
        }
        .aspectRatio(document.canvas.width / max(1, document.canvas.height), contentMode: .fit)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hosts: [CanvasSurveyHostElement] {
        document.canvasHosts + document.sharedUiHosts.map(CanvasSurveyHostElement.managed)
    }
}

private struct CanvasSurveyHostView: View {
    let host: CanvasSurveyHostElement
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

    var body: some View {
        switch host {
        case .answer:
            if let block, let answerNodeId, !block.type.isContent {
                ScrollView(.vertical, showsIndicators: false) {
                    SurveyQuestionContent(
                        block: block,
                        answer: vm.answers[answerNodeId],
                        accent: accent,
                        onAnswer: { vm.setAnswer(answerNodeId, $0) }
                    )
                }
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
                onClose: onClose
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

    var body: some View {
        if host.visible {
            switch host.role {
            case .progress:
                CanvasSurveyProgressHost(host: host, progress: vm.progress, currentSegment: vm.currentItemIndex, totalSegments: survey.nodes.count)
            case .pageCount:
                CanvasSurveyTextHost(host: host, text: "\(vm.currentItemIndex)/\(max(1, survey.nodes.count))")
            case .timer:
                if survey.settings.timer.enabled && survey.settings.timer.timeLimitSeconds > 0 {
                    CanvasSurveyTextHost(host: host, text: formatRemaining(remainingSecs))
                }
            case .primaryNavigation:
                let isResult = block?.type == .resultPage
                let label = isResult ? host.doneLabel.nonEmpty(or: "Done") : host.label.nonEmpty(or: "Next")
                CanvasSurveyButtonHost(
                    host: host,
                    text: label,
                    enabled: isResult || block == nil || vm.canAdvance(),
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
                if showCloseButton && survey.settings.display.dismissible {
                    CanvasSurveyDismissHost(host: host, onClose: onClose)
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
    let accent: Color
    let onClick: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let button = host.button, enabled {
            CampaignCanvasRendererRegistry.render(
                button,
                isDark: CampaignCanvasTheme.shared.isDark(colorScheme),
                onAction: { _ in onClick() }
            )
        } else {
            let fill = Color(hex: host.fillHex) ?? accent
            let foreground = Color(hex: host.colorHex) ?? Color.white
            Button(action: onClick) {
                Text(text)
                    .font(surveyFont(size: host.fontSize, weight: 600))
                    .foregroundColor(enabled ? foreground : foreground.opacity(0.55))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: host.cornerRadius)
                            .fill(enabled ? fill : fill.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
    }
}

private struct CanvasSurveyDismissHost: View {
    let host: CanvasSurveyManagedHostElement
    let onClose: () -> Void

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(surveyFont(size: host.iconSize > 0 ? host.iconSize : host.fontSize, weight: 600))
                .foregroundColor(
                    host.iconColorHex.flatMap(Color.init(hex:))
                        ?? Color(hex: host.colorHex)
                        ?? SurveyTokens.textTertiary
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
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
                    .stroke(Color(hex: host.borderColorHex) ?? Color.clear, lineWidth: host.borderWidth)
            )
    }
}

private func formatRemaining(_ remainingSecs: Int) -> String {
    String(format: "%d:%02d", remainingSecs / 60, remainingSecs % 60)
}

private extension String {
    func nonEmpty(or fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
