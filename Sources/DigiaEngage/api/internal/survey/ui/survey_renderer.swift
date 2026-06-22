import SwiftUI
import UIKit
import Combine

/// Frame-settling buffer added before the survey is shown.
private let RENDER_DELAY_MS: Int = 150

/// Top-level survey overlay — mounted once inside `DigiaHost`. Mirrors the
/// dashboard `BlockEditor` visual language: a card with thin progress bar,
/// category pill, title/body, type-specific content, and footer CTAs.
@MainActor
struct SurveyRenderer: View {
    @ObservedObject var orchestrator: SurveyOrchestrator

    var body: some View {
        Group {
            if let state = orchestrator.state {
                SurveySession(state: state, orchestrator: orchestrator)
                    .id(state.token)
            }
        }
    }
}

@MainActor
private struct SurveySession: View {
    let state: ActiveSurveyState
    let orchestrator: SurveyOrchestrator
    @StateObject private var vm: SurveyViewModel
    @State private var visible = false

    init(state: ActiveSurveyState, orchestrator: SurveyOrchestrator) {
        self.state = state
        self.orchestrator = orchestrator
        _vm = StateObject(wrappedValue: SurveyViewModel(survey: state.config))
    }

    var body: some View {
        let survey = state.config
        let accent = Color(hex: survey.theme.accentHex) ?? Color.blue
        let background = Color(hex: survey.theme.backgroundHex) ?? Color.white
        let display = survey.settings.display

        ZStack {
            if visible && !vm.isComplete && display.type == .dialog {
                DialogContainer(
                    dialog: display.dialog,
                    background: background,
                    onDismiss: { finish(completed: false) },
                    content: {
                        SurveyBody(
                            vm: vm,
                            survey: survey,
                            accent: accent,
                            onClose: { finish(completed: false) },
                            onCompletedClose: { SDKInstance.shared.dismissCompletedSurvey() },
                            showCloseButton: display.dialog.showCloseButton
                        )
                    }
                )
                .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: sheetPresented) {
            SurveySheet(
                sheet: display.bottomSheet,
                background: background,
                onDismiss: { finish(completed: false) }
            ) {
                SurveyBody(
                    vm: vm,
                    survey: survey,
                    accent: accent,
                    onClose: { finish(completed: false) },
                    onCompletedClose: { SDKInstance.shared.dismissCompletedSurvey() },
                    showCloseButton: display.bottomSheet.backdropDismissible
                )
            }
            .presentationBackground(.clear)
        }
        .transaction { $0.disablesAnimations = true }
        .task(id: state.token) {
            let delayNs = UInt64(max(0, survey.timeDelayMs + RENDER_DELAY_MS)) * 1_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            SDKInstance.shared.reportSurveyStarted()
            visible = true
        }
        .onChange(of: vm.isComplete) { complete in
            if complete { finish(completed: true) }
        }
        .onChange(of: vm.redirectUrl) { url in
            guard let url, let parsed = URL(string: url) else { return }
            UIApplication.shared.open(parsed)
        }
    }

    private func finish(completed: Bool) {
        if completed {
            SDKInstance.shared.markSurveyCompleted(response: vm.responsePayload(), answers: vm.answers)
        } else {
            SDKInstance.shared.markSurveyDismissed(
                abandonedAtItem: vm.currentItemIndex,
                answeredCount: vm.answers.values.filter { $0.isAnswered }.count
            )
        }
    }

    /// Drives the full-screen cover for bottom-sheet surveys. The sheet's own
    /// drag/backdrop dismissal calls `finish(completed:)` directly (via
    /// `onDismiss`); this binding's setter is a safety net for any programmatic
    /// clear, also routing through `finish(completed:)`.
    private var sheetPresented: Binding<Bool> {
        Binding(
            get: {
                visible && !vm.isComplete
                    && state.config.settings.display.type == .bottomSheet
            },
            set: { presented in if !presented { finish(completed: false) } }
        )
    }
}

// MARK: - Containers

/// Maps the survey's `BottomSheetProps` onto the shared `DigiaBottomSheet`. The
/// survey body manages its own internal scrolling (`ContentSizedScrollView`), so
/// it renders with `scrollable: false`.
private struct SurveySheet<Content: View>: View {
    let sheet: BottomSheetProps
    let background: Color
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    /// `heightMode` becomes the sheet's *cap*, not a fixed height: short content
    /// hugs (no dead space), taller content scrolls within this ceiling.
    private var heightCapFraction: CGFloat {
        switch sheet.heightMode {
        case .wrap:   return 0.95
        case .half:   return 0.5
        case .full:   return 0.98
        case .custom: return CGFloat(max(10, min(100, sheet.customHeight))) / 100.0
        }
    }

    var body: some View {
        DigiaBottomSheet(
            config: DigiaBottomSheetConfig(
                cornerRadius: CGFloat(sheet.cornerRadius),
                background: background,
                showHandle: sheet.showHandle,
                allowInteractiveDismiss: sheet.draggable || sheet.backdropDismissible,
                heightCapFraction: heightCapFraction
            ),
            scrollable: false,
            onDismiss: onDismiss,
            content: content
        )
    }
}

private struct DialogContainer<Content: View>: View {
    let dialog: DialogProps
    let background: Color
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    // Blocks the first-frame backdrop tap from closing the survey before the
    // CTA Buttons' gesture recognisers are interactive.
    @State private var armed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(dialog.backdropOpacity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if armed && dialog.backdropDismissible { onDismiss() }
                    }

                content()
                    .frame(width: dialogWidth(geo: geo))
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat(dialog.cornerRadius))
                            .fill(background)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(dialog.cornerRadius)))
                    .padding(16)
            }
            .task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                armed = true
            }
        }
    }

    private func dialogWidth(geo: GeometryProxy) -> CGFloat {
        geo.size.width - 32
    }
}

private struct HeightCappedLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let measured = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(
            width: proposal.width ?? measured.width,
            height: min(measured.height, maxHeight)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private struct ContentSizedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        HeightCappedLayout(maxHeight: maxHeight) {
            ScrollView(.vertical, showsIndicators: false) {
                content()
            }
        }
    }
}

// MARK: - SurveyBody

@MainActor
private struct SurveyBody: View {
    @ObservedObject var vm: SurveyViewModel
    let survey: SurveyConfigModel
    let accent: Color
    let onClose: () -> Void
    let onCompletedClose: () -> Void
    let showCloseButton: Bool

    @State private var remainingSecs: Int = 0
    @State private var autoAdvanceTask: Task<Void, Never>?
    @State private var timerTask: Task<Void, Never>?
    @State private var lastAutoAdvanceKey: String = ""
    @State private var welcomeDone = false
    @State private var completionReported = false

    var body: some View {
        Group {
            if let welcome = survey.welcomeBlock(), !welcomeDone {
                welcomeScreen(welcome)
            } else if let node = vm.currentNode, let block = survey.blockFor(node) {
                bodyContent(node: node, block: block)
            } else {
                EmptyView()
            }
        }
    }

    /// Fixed intro chrome shown before the node flow (the welcome block is not a
    /// graph node). Mirrors Android's `WelcomeScreen`.
    @ViewBuilder
    private func welcomeScreen(_ block: SurveyBlock) -> some View {
        let cta = survey.settings.cta
        VStack(alignment: .leading, spacing: 12) {
            if showCloseButton && survey.settings.display.dismissible {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(surveyFont(size: 14, weight: .semibold))
                            .foregroundColor(SurveyTokens.textTertiary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                }
            }
            if block.showMedia && block.media.position == .top {
                BlockMediaImage(media: block.media)
            }
            BlockTitleView(block: block, accent: accent)
            if block.showMedia && block.media.position == .inline {
                BlockMediaImage(media: block.media)
            }
            Button {
                // The welcome "Start" tap is the survey's start-engagement signal
                // ("Digia Experience Clicked" / welcome_start).
                SDKInstance.shared.reportSurveyWelcomeStart()
                welcomeDone = true
            } label: {
                Text(cta.startLabel)
                    .font(surveyFont(size: 15, weight: .semibold))
                    .foregroundColor(ctaText(cta))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: cta.layout == .stacked ? .infinity : nil)
                    .background(RoundedRectangle(cornerRadius: CGFloat(cta.cornerRadius)).fill(ctaBg(cta, accent)))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: block.backgroundColor) ?? Color.clear)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func bodyContent(node: SurveyNode, block: SurveyBlock) -> some View {
        let timerCfg = survey.settings.timer
        let currentAnswer = vm.answers[node.id]

        VStack(alignment: .leading, spacing: 0) {
            topRow(node: node, block: block)
            Spacer().frame(height: 14)
            scrollSection(node: node, block: block)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: block.backgroundColor) ?? Color.clear)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if timerCfg.enabled && timerCfg.timeLimitSeconds > 0 && remainingSecs == 0 {
                remainingSecs = timerCfg.timeLimitSeconds
                startTimer(paused: timerCfg.pauseOnNonTimerBlock && block.type.isContent)
            }
            scheduleAutoAdvanceIfNeeded()
        }
        .onChange(of: vm.currentNodeId) { _ in
            let paused = timerCfg.pauseOnNonTimerBlock && (vm.currentBlock?.type.isContent == true)
            restartTimer(paused: paused, total: timerCfg.timeLimitSeconds, enabled: timerCfg.enabled)
            scheduleAutoAdvanceIfNeeded()
        }
        .onChange(of: currentAnswer) { _ in
            scheduleAutoAdvanceIfNeeded()
        }
    }

    @ViewBuilder
    private func topRow(node: SurveyNode, block: SurveyBlock) -> some View {
        let pagination = survey.settings.pagination
        let timerCfg = survey.settings.timer
        let position = (survey.nodes.firstIndex(where: { $0.id == node.id }) ?? 0) + 1
        let total = max(1, survey.nodes.count)
        let showBarHere = pagination.progressbar && !(pagination.onlyShowOnQuestionBlock && block.type.isContent)

        HStack(spacing: 10) {
            if showBarHere {
                ProgressBar(
                    progress: Double(position) / Double(total),
                    style: pagination.paginationStyle,
                    segments: total,
                    currentSegment: position,
                    accent: accent,
                    indicator: pagination.progressIndicatorStyle
                )
                .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            if pagination.numberOfPages && !block.type.isContent {
                Text("\(position)/\(total)")
                    .font(surveyFont(size: 11, weight: .semibold))
                    .foregroundColor(SurveyTokens.textTertiary)
            }
            if timerCfg.enabled && timerCfg.timeLimitSeconds > 0 {
                TimerChip(remainingSecs: remainingSecs, warningAtSecs: timerCfg.warningAtSeconds, accent: accent)
            }
            if showCloseButton && survey.settings.display.dismissible {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(surveyFont(size: 14, weight: .semibold))
                        .foregroundColor(SurveyTokens.textTertiary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func scrollSection(node: SurveyNode, block: SurveyBlock) -> some View {
        let maxHeight = scrollMaxHeight(flexible: block.flexibleHeight)

        ContentSizedScrollView(maxHeight: maxHeight) {
            surveyContent(node: node, block: block)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func surveyContent(node: SurveyNode, block: SurveyBlock) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if block.showMedia && block.media.position == .top {
                BlockMediaImage(media: block.media)
            }
            CategoryPill(block: block, accent: accent)
            BlockTitleView(block: block, accent: accent)
            if block.showMedia && block.media.position == .inline {
                BlockMediaImage(media: block.media)
            }
            blockContent(node: node, block: block)
            footerSection(node: node, block: block)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(node.id)
    }

    private func scrollMaxHeight(flexible: Bool) -> CGFloat {
        // Cap is the smaller of (fixed limit) and a screen-relative budget so
        // the surrounding SurveyBody never exceeds the dialog/sheet on small phones.
        let screen = UIScreen.main.bounds.height
        if flexible { return min(screen * 0.6, screen - 240) }
        return min(480, screen * 0.5)
    }

    @ViewBuilder
    private func footerSection(node: SurveyNode, block: SurveyBlock) -> some View {
        let hasInlineCta = block.type == .welcome || block.type == .resultPage
        let canAutoAdvanceThisBlock = survey.settings.autoAdvance && block.type.isAutoAdvanceCandidate
        let showNext = !hasInlineCta && (survey.settings.chooseButton || !canAutoAdvanceThisBlock)

        if showNext {
            Spacer().frame(height: 18)
            FooterRow(
                cta: survey.settings.cta,
                accent: accent,
                canGoBack: vm.canGoBack,
                onBack: { vm.back() },
                nextEnabled: vm.canAdvance(),
                nextLabel: footerNextLabel(survey: survey, node: node, block: block),
                onNext: {
                    if !block.type.isContent {
                        if let ans = vm.answers[node.id], ans.isAnswered {
                            SDKInstance.shared.reportSurveyAnswered(stepId: node.id, answer: ans.toMap())
                        } else {
                            SDKInstance.shared.reportSurveyQuestionSkipped(nodeId: node.id, itemIndex: vm.currentItemIndex)
                        }
                    }
                    reportCompletionIfResultIsNext()
                    vm.advance()
                }
            )
        }
    }

    @ViewBuilder
    private func blockContent(node: SurveyNode, block: SurveyBlock) -> some View {
        let cta = survey.settings.cta
        switch block.type {
        case .welcome:
            Button {
                SDKInstance.shared.reportSurveyWelcomeStart()
                vm.advance()
            } label: {
                Text(cta.startLabel)
                    .font(surveyFont(size: 15, weight: .semibold))
                    .foregroundColor(ctaText(cta))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: CGFloat(cta.cornerRadius)).fill(ctaBg(cta, accent)))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        case .resultPage:
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    onCompletedClose()
                } label: {
                    Text(cta.doneLabel)
                        .font(surveyFont(size: 14, weight: .semibold))
                        .foregroundColor(ctaText(cta))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .frame(maxWidth: cta.layout == .stacked ? .infinity : nil)
                        .background(RoundedRectangle(cornerRadius: CGFloat(cta.cornerRadius)).fill(ctaBg(cta, accent)))
                }
                .buttonStyle(.plain)
            }
        case .textMedia:
            if !block.media.hasUrl { MediaPlaceholder() }
        default:
            SurveyQuestionContent(
                block: block,
                answer: vm.answers[node.id],
                accent: accent,
                onAnswer: { vm.setAnswer(node.id, $0) }
            )
            .onAppear {
                SDKInstance.shared.reportSurveyQuestionViewed(nodeId: node.id, itemIndex: vm.currentItemIndex)
            }
        }
    }

    private func scheduleAutoAdvanceIfNeeded() {
        guard let node = vm.currentNode, let block = vm.currentBlock else { return }
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

    private func startTimer(paused: Bool) {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while remainingSecs > 0 {
                if Task.isCancelled { return }
                if !paused {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    remainingSecs = max(0, remainingSecs - 1)
                } else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            if remainingSecs == 0 { onClose() }
        }
    }

    private func restartTimer(paused: Bool, total: Int, enabled: Bool) {
        guard enabled && total > 0 else { return }
        startTimer(paused: paused)
    }
}

// MARK: - Chrome pieces

private struct ProgressBar: View {
    let progress: Double
    let style: PaginationStyle
    let segments: Int
    let currentSegment: Int
    let accent: Color
    var indicator: ProgressIndicatorStyle = .default

    private var activeColor: Color { Color(hex: indicator.activeColorHex) ?? accent }
    private var trackColor: Color { Color(hex: indicator.trackColorHex) ?? SurveyTokens.surfaceSunken }
    private var height: CGFloat { CGFloat(indicator.height) }
    private var radius: CGFloat { CGFloat(indicator.cornerRadius) }

    var body: some View {
        if style == .segmented && segments > 1 {
            HStack(spacing: 3) {
                ForEach(1...segments, id: \.self) { i in
                    let on = i <= currentSegment
                    RoundedRectangle(cornerRadius: radius)
                        .fill(on ? activeColor : trackColor)
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: radius).fill(trackColor)
                    RoundedRectangle(cornerRadius: radius)
                        .fill(activeColor)
                        .frame(width: geo.size.width * min(1, max(0, progress)))
                }
            }
            .frame(height: height)
        }
    }
}

private struct TimerChip: View {
    let remainingSecs: Int
    let warningAtSecs: Int
    let accent: Color

    var body: some View {
        let warn = warningAtSecs > 0 && remainingSecs <= warningAtSecs
        let tint = warn ? SurveyTokens.errorRed : accent
        let minutes = remainingSecs / 60
        let seconds = remainingSecs % 60
        Text(String(format: "%d:%02d", minutes, seconds))
            .font(surveyFont(size: 11, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

private struct CategoryPill: View {
    let block: SurveyBlock
    let accent: Color

    var body: some View {
        if block.type.isContent || !block.showTag {
            EmptyView()
        } else if let label = categoryLabel(block.type) {
            Text(label.uppercased())
                .font(surveyFont(size: 10.5, weight: .bold))
                .foregroundColor(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(accent.opacity(0.12)))
        }
    }
}

private struct BlockTitleView: View {
    let block: SurveyBlock
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !block.title.text.isEmpty {
                StyledText(text: block.title.text, style: block.title.style, accent: accent, defaults: TitleDefaults)
            }
            if let body = block.body, !body.text.isEmpty {
                StyledText(text: body.text, style: body.style, accent: accent, defaults: BodyDefaults)
            }
        }
    }
}

private struct BlockMediaImage: View {
    let media: BlockMedia

    private var contentMode: ContentMode {
        switch media.boxFit {
        case "contain": return .fit
        default: return .fill
        }
    }

    var body: some View {
        if media.hasUrl, let url = URL(string: media.url) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: contentMode)
            } placeholder: {
                SurveyTokens.surfaceSunken
            }
            .frame(height: 176)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(SurveyTokens.border, lineWidth: 1))
        }
    }
}

private struct MediaPlaceholder: View {
    var body: some View {
        Text("— image / video —")
            .font(surveyFont(size: 12))
            .foregroundColor(SurveyTokens.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 10).fill(SurveyTokens.surfaceSunken))
    }
}

/// Resolved CTA background — explicit hex, else the theme accent.
private func ctaBg(_ cta: CtaSettings, _ accent: Color) -> Color {
    Color(hex: cta.bgColorHex) ?? accent
}
/// Resolved CTA text colour — explicit hex, else white.
private func ctaText(_ cta: CtaSettings) -> Color {
    Color(hex: cta.textColorHex) ?? .white
}

private struct FooterRow: View {
    let cta: CtaSettings
    let accent: Color
    let canGoBack: Bool
    let onBack: () -> Void
    let nextEnabled: Bool
    let nextLabel: String
    let onNext: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: CGFloat(cta.cornerRadius)) }

    @ViewBuilder
    private func nextButton(fullWidth: Bool) -> some View {
        Button(action: onNext) {
            Text(nextLabel)
                .font(surveyFont(size: 14, weight: .semibold))
                .foregroundColor(ctaText(cta))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(shape.fill(nextEnabled ? ctaBg(cta, accent) : ctaBg(cta, accent).opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!nextEnabled)
    }

    @ViewBuilder
    private func backButton(fullWidth: Bool) -> some View {
        Button(action: onBack) {
            Text(cta.backLabel)
                .font(surveyFont(size: 14))
                .foregroundColor(SurveyTokens.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .overlay(fullWidth ? AnyView(shape.stroke(SurveyTokens.border, lineWidth: 1)) : AnyView(EmptyView()))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        if cta.layout == .stacked {
            VStack(spacing: 10) {
                nextButton(fullWidth: true)
                if canGoBack { backButton(fullWidth: true) }
            }
            .frame(maxWidth: .infinity)
        } else {
            inlineRow
        }
    }

    @ViewBuilder
    private var inlineRow: some View {
        HStack(spacing: 12) {
            switch cta.arrangement {
            case .spaceBetween:
                if canGoBack { backButton(fullWidth: false) }
                Spacer(minLength: 0)
                nextButton(fullWidth: false)
            case .end:
                Spacer(minLength: 0)
                if canGoBack { backButton(fullWidth: false) }
                nextButton(fullWidth: false)
            case .start:
                if canGoBack { backButton(fullWidth: false) }
                nextButton(fullWidth: false)
                Spacer(minLength: 0)
            case .center:
                Spacer(minLength: 0)
                if canGoBack { backButton(fullWidth: false) }
                nextButton(fullWidth: false)
                Spacer(minLength: 0)
            case .spaceEvenly:
                Spacer(minLength: 0)
                if canGoBack { backButton(fullWidth: false); Spacer(minLength: 0) }
                nextButton(fullWidth: false)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Helpers

private func footerNextLabel(survey: SurveyConfigModel, node: SurveyNode, block: SurveyBlock) -> String {
    let cta = survey.settings.cta
    if block.type == .textMedia { return cta.nextLabel }
    let target = node.branching.defaultTarget
    let noRules = node.branching.rules.isEmpty
    let terminates: Bool
    if noRules {
        switch target.kind {
        case .end:
            terminates = true
        case .next:
            terminates = (survey.nodes.firstIndex(where: { $0.id == node.id }) == survey.nodes.count - 1)
        default:
            terminates = false
        }
    } else {
        terminates = false
    }
    return terminates ? cta.doneLabel : cta.nextLabel
}

private func categoryLabel(_ type: SurveyBlockType) -> String? {
    switch type {
    case .singleSelect: return "Select one answer"
    case .multiSelect: return "Select all that apply"
    case .rating: return "Rate it"
    case .nps, .npsEmoji, .npsSmiley: return "Promoter score"
    case .reaction: return "Reaction poll"
    case .thisOrThat: return "This or that"
    case .tierList: return "Tier list"
    case .upvote: return "Upvote"
    case .shortText: return "Short text"
    case .longText: return "Long text"
    case .number: return "Number"
    case .email: return "Email"
    case .date: return "Date picker"
    case .welcome, .textMedia, .resultPage: return nil
    }
}
