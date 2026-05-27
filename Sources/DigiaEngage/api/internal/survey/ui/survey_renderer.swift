import SwiftUI
import UIKit

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
                let _ = print("[Digia] SurveyRenderer — mounting SurveySession token=\(state.token)")
                SurveySession(state: state, orchestrator: orchestrator)
                    .id(state.token)
            } else {
                let _ = print("[Digia] SurveyRenderer — orchestrator.state is nil")
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
            Color.clear
            if visible && !vm.isComplete {
                ZStack {
                    switch display.type {
                    case .bottomSheet:
                        BottomSheetContainer(
                            sheet: display.bottomSheet,
                            background: background,
                            onDismiss: { finish(completed: false) },
                            content: {
                                SurveyBody(
                                    vm: vm,
                                    survey: survey,
                                    accent: accent,
                                    onClose: { finish(completed: false) },
                                    showCloseButton: display.bottomSheet.backdropDismissible
                                )
                            }
                        )
                    case .dialog:
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
                                    showCloseButton: display.dialog.showCloseButton
                                )
                            }
                        )
                    }
                }
                .transition(.opacity)
            }
        }
        .task(id: state.token) {
            print("[Digia] SurveySession — task fired, timeDelayMs=\(survey.timeDelayMs), display=\(display.type), isComplete=\(vm.isComplete)")
            let delayNs = UInt64(max(0, survey.timeDelayMs + RENDER_DELAY_MS)) * 1_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            SDKInstance.shared.reportSurveyStarted()
            visible = true
            print("[Digia] SurveySession — visible=true (after \(survey.timeDelayMs + RENDER_DELAY_MS)ms delay)")
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
            SDKInstance.shared.markSurveyDismissed()
        }
    }
}

// MARK: - Containers

private struct BottomSheetContainer<Content: View>: View {
    let sheet: BottomSheetProps
    let background: Color
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if sheet.backdropDismissible { onDismiss() }
                    }

                VStack(spacing: 0) {
                    if sheet.showHandle {
                        Capsule()
                            .fill(SurveyTokens.border)
                            .frame(width: 40, height: 4)
                            .padding(.vertical, 8)
                    }
                    content()
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: sheetMaxHeight(geo: geo), alignment: .top)
                .modifier(WrapHeightIfNeeded(wrap: sheet.heightMode == .wrap))
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: CGFloat(sheet.cornerRadius),
                        topTrailingRadius: CGFloat(sheet.cornerRadius)
                    )
                    .fill(background)
                )
                .offset(y: dragOffset)
                .gesture(
                    sheet.draggable
                        ? DragGesture()
                            .onChanged { value in
                                dragOffset = max(0, value.translation.height)
                            }
                            .onEnded { value in
                                if value.translation.height > 150 {
                                    onDismiss()
                                } else {
                                    withAnimation(.easeOut) { dragOffset = 0 }
                                }
                            }
                        : nil
                )
                .padding(.bottom, geo.safeAreaInsets.bottom)
            }
        }
    }

    private func sheetMaxHeight(geo: GeometryProxy) -> CGFloat {
        let screen = geo.size.height
        switch sheet.heightMode {
        case .wrap: return screen // safety cap only; fixedSize makes content drive size
        case .half: return screen * 0.5
        case .full: return screen
        case .custom:
            let pct = Double(max(10, min(100, sheet.customHeight))) / 100.0
            return screen * pct
        }
    }
}

private struct WrapHeightIfNeeded: ViewModifier {
    let wrap: Bool
    func body(content: Content) -> some View {
        if wrap {
            content.fixedSize(horizontal: false, vertical: true)
        } else {
            content
        }
    }
}

private struct UnevenRoundedRectangle: Shape {
    var topLeadingRadius: CGFloat = 0
    var topTrailingRadius: CGFloat = 0
    var bottomLeadingRadius: CGFloat = 0
    var bottomTrailingRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = topLeadingRadius
        let tr = topTrailingRadius
        let bl = bottomLeadingRadius
        let br = bottomTrailingRadius
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                        radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                        radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                        radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                        radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath()
        return path
    }
}

private struct DialogContainer<Content: View>: View {
    let dialog: DialogProps
    let background: Color
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(dialog.backdropOpacity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if dialog.backdropDismissible { onDismiss() }
                    }

                content()
                    .frame(width: dialogWidth(geo: geo))
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat(dialog.cornerRadius))
                            .fill(background)
                    )
                    .padding(16)
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
    let showCloseButton: Bool

    @State private var remainingSecs: Int = 0
    @State private var autoAdvanceTask: Task<Void, Never>?
    @State private var timerTask: Task<Void, Never>?
    @State private var lastAutoAdvanceKey: String = ""

    var body: some View {
        Group {
            if let node = vm.currentNode, let block = survey.blockFor(node) {
                bodyContent(node: node, block: block)
            } else {
                EmptyView()
            }
        }
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
                    accent: accent
                )
                .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            if pagination.numberOfPages && !block.type.isContent {
                Text("\(position)/\(total)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(SurveyTokens.textTertiary)
            }
            if timerCfg.enabled && timerCfg.timeLimitSeconds > 0 {
                TimerChip(remainingSecs: remainingSecs, warningAtSecs: timerCfg.warningAtSeconds, accent: accent)
            }
            if showCloseButton && survey.settings.display.dismissible {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
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
                accent: accent,
                canGoBack: vm.canGoBack,
                onBack: { vm.back() },
                nextEnabled: vm.canAdvance(),
                nextLabel: footerNextLabel(survey: survey, node: node, block: block),
                onNext: {
                    if !block.type.isContent {
                        if let ans = vm.answers[node.id], ans.isAnswered {
                            SDKInstance.shared.reportSurveyAnswered(stepId: node.id, answer: ans.toMap())
                        }
                    }
                    vm.advance()
                }
            )
        }
    }

    @ViewBuilder
    private func blockContent(node: SurveyNode, block: SurveyBlock) -> some View {
        switch block.type {
        case .welcome:
            Button {
                SDKInstance.shared.reportSurveyAnswered(stepId: node.id, answer: [:])
                vm.advance()
            } label: {
                Text("Start →")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        case .resultPage:
            VStack(alignment: .leading, spacing: 10) {
                Text("✓ Response recorded. Aggregate results display here for users who completed.")
                    .font(.system(size: 13))
                    .foregroundColor(SurveyTokens.textSecondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(SurveyTokens.surfaceSunken))
                Button {
                    vm.advance()
                } label: {
                    Text("Done")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(SurveyTokens.textPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SurveyTokens.border, lineWidth: 1))
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
            vm.advance()
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

    var body: some View {
        if style == .segmented && segments > 1 {
            HStack(spacing: 3) {
                ForEach(1...segments, id: \.self) { i in
                    let on = i <= currentSegment
                    RoundedRectangle(cornerRadius: 2)
                        .fill(on ? accent : SurveyTokens.surfaceSunken)
                        .frame(height: 3)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(SurveyTokens.surfaceSunken)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent)
                        .frame(width: geo.size.width * min(1, max(0, progress)))
                }
            }
            .frame(height: 3)
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
            .font(.system(size: 11, weight: .semibold))
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
        if block.type.isContent {
            EmptyView()
        } else if let label = categoryLabel(block.type) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .bold))
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

    var body: some View {
        if media.hasUrl, let url = URL(string: media.url) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
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
            .font(.system(size: 12))
            .foregroundColor(SurveyTokens.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 10).fill(SurveyTokens.surfaceSunken))
    }
}

private struct FooterRow: View {
    let accent: Color
    let canGoBack: Bool
    let onBack: () -> Void
    let nextEnabled: Bool
    let nextLabel: String
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if canGoBack {
                Button(action: onBack) {
                    Text("← Back")
                        .font(.system(size: 14))
                        .foregroundColor(SurveyTokens.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
            Button(action: onNext) {
                Text(nextLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(nextEnabled ? accent : accent.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!nextEnabled)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Helpers

private func footerNextLabel(survey: SurveyConfigModel, node: SurveyNode, block: SurveyBlock) -> String {
    if block.type == .textMedia { return "Next" }
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
    return terminates ? "Finish" : "Next"
}

private func categoryLabel(_ type: SurveyBlockType) -> String? {
    switch type {
    case .singleSelect: return "Select one answer"
    case .multiSelect: return "Select all that apply"
    case .rating: return "Rate it"
    case .nps: return "Promoter score"
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
