import SwiftUI
import UIKit
import Combine
@_implementationOnly import SDWebImageSwiftUI

/// Frame-settling buffer added before the survey is shown.
private let RENDER_DELAY_MS: Int = 150

private final class SurveyKeyboardObserver: ObservableObject, @unchecked Sendable {
    @Published private var keyboardMinY: CGFloat?
    @Published private(set) var animationDuration: TimeInterval = 0.25
    private var animationCurve = UIView.AnimationCurve.easeInOut.rawValue

    var animation: Animation {
        switch animationCurve {
        case UIView.AnimationCurve.easeIn.rawValue: return .easeIn(duration: animationDuration)
        case UIView.AnimationCurve.easeOut.rawValue: return .easeOut(duration: animationDuration)
        case UIView.AnimationCurve.linear.rawValue: return .linear(duration: animationDuration)
        default: return .easeInOut(duration: animationDuration)
        }
    }

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handle(notification)
            },
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handle(notification)
            }
        ]
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handle(_ notification: Notification) {
        animationCurve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?
            .intValue ?? UIView.AnimationCurve.easeInOut.rawValue
        animationDuration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
            .doubleValue ?? 0.25

        guard notification.name != UIResponder.keyboardWillHideNotification,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else {
            keyboardMinY = nil
            return
        }

        keyboardMinY = frame.minY
    }

    func bottomInset(overlapping rect: CGRect) -> CGFloat {
        guard let keyboardMinY else { return 0 }
        return max(0, rect.maxY - keyboardMinY)
    }
}

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
                    .environment(\.digiaVariables, state.variableContext)
            }
        }
        // Default every raw Text/TextField/TextEditor to the SDK-wide family.
        // Elements with authored sizes still override this through surveyFont(...).
        .font(surveyFont(size: 14))
    }
}

@MainActor
private struct SurveySession: View {
    let state: ActiveSurveyState
    let orchestrator: SurveyOrchestrator
    @StateObject private var vm: SurveyViewModel
    @State private var visible = false
    @State private var canvasWelcomeDone = false
    @State private var impressionReported = false

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
                    keyboardScrollsContent: survey.canvasSurvey != nil,
                    separateClose: display.dialog.showCloseButton ? survey.canvasSurvey?.closeButton : nil,
                    onDismiss: { finish(completed: false) },
                    content: {
                        SurveyPanelContent(
                            vm: vm,
                            survey: survey,
                            accent: accent,
                            onClose: { finish(completed: false) },
                            onCompletedClose: { SDKInstance.shared.dismissCompletedSurvey() },
                            showCloseButton: display.dialog.showCloseButton,
                            paintCanvasBackground: true,
                            canvasWelcomeDone: $canvasWelcomeDone
                        )
                    }
                )
                .onAppear { reportVisible() }
                .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: sheetPresented) {
            let sheetContent = SurveySheet(
                sheet: display.bottomSheet,
                background: background,
                canvasBackground: canvasSurveySheetBackground(survey),
                animateContentHeight: survey.canvasSurvey != nil,
                keyboardScrollsContent: survey.canvasSurvey != nil,
                separateClose: display.bottomSheet.showCloseButton ? survey.canvasSurvey?.closeButton : nil,
                onDismiss: { finish(completed: false) }
            ) {
                SurveyPanelContent(
                    vm: vm,
                    survey: survey,
                    accent: accent,
                    onClose: { finish(completed: false) },
                    onCompletedClose: { SDKInstance.shared.dismissCompletedSurvey() },
                    showCloseButton: display.bottomSheet.showCloseButton,
                    paintCanvasBackground: survey.canvasSurvey == nil,
                    canvasWelcomeDone: $canvasWelcomeDone
                )
            }
            let guardedSheetContent = sheetContent
                .interactiveDismissDisabled(true)
                .onAppear { reportVisible() }
            // `.presentationBackground` needs iOS 16.4; below that, the cover's
            // (opaque) default background is used as-is.
            if #available(iOS 16.4, *) {
                guardedSheetContent.presentationBackground(.clear)
            } else {
                guardedSheetContent
            }
        }
        .transaction { $0.disablesAnimations = true }
        .task(id: state.token) {
            let delayNs = UInt64(max(0, survey.timeDelayMs + RENDER_DELAY_MS)) * 1_000_000
            try? await Task.sleep(nanoseconds: delayNs)
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

    private func reportVisible() {
        guard !impressionReported else { return }
        impressionReported = true
        SDKInstance.shared.reportSurveyStarted()
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

@MainActor
private struct SurveyPanelContent: View {
    @ObservedObject var vm: SurveyViewModel
    let survey: SurveyConfigModel
    let accent: Color
    let onClose: () -> Void
    let onCompletedClose: () -> Void
    let showCloseButton: Bool
    let paintCanvasBackground: Bool
    @Binding var canvasWelcomeDone: Bool

    var body: some View {
        if let canvasSurvey = survey.canvasSurvey {
            CanvasSurveyPanel(
                vm: vm,
                survey: survey,
                canvasSurvey: canvasSurvey,
                accent: accent,
                onClose: onClose,
                onCompletedClose: onCompletedClose,
                showCloseButton: showCloseButton,
                paintBackground: paintCanvasBackground,
                welcomeDone: $canvasWelcomeDone
            )
        } else {
            SurveyBody(
                vm: vm,
                survey: survey,
                accent: accent,
                onClose: onClose,
                onCompletedClose: onCompletedClose,
                showCloseButton: showCloseButton
            )
        }
    }
}

/// Maps the survey's `BottomSheetProps` onto the shared `DigiaBottomSheet`. The
/// survey body manages its own internal scrolling, except canvas surveys while
/// the keyboard is visible: those need sheet-level scrolling to keep oversized
/// authored canvases reachable above the keyboard.
@MainActor
private struct SurveySheet<Content: View>: View {
    let sheet: BottomSheetProps
    let background: Color
    let canvasBackground: CampaignCanvasPaint?
    let animateContentHeight: Bool
    let keyboardScrollsContent: Bool
    let separateClose: NudgeCloseButtonConfig?
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @StateObject private var keyboard = SurveyKeyboardObserver()

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
        GeometryReader { geo in
            let keyboardInset = keyboard.bottomInset(overlapping: geo.frame(in: .global))
            let safeAreaMode: BottomSafeAreaMode = keyboardInset > 0
                ? .insetSurface
                : sheet.bottomSafeAreaMode
            let bottomInset = keyboardInset > 0
                ? keyboardInset
                : (safeAreaMode == .none ? 0 : surveyWindowSafeAreaInsets.bottom)
            DigiaBottomSheet(
                config: DigiaBottomSheetConfig(
                    cornerRadius: CGFloat(sheet.cornerRadius),
                    background: canvasBackground == nil ? background : .clear,
                    scrimColor: Color(hex: sheet.backdropColorHex) ?? Color.black.opacity(sheet.backdropOpacity),
                    showHandle: sheet.showHandle,
                    allowBackdropDismiss: sheet.backdropDismissible,
                    allowDragDismiss: sheet.draggable && keyboardInset == 0,
                    heightCapFraction: heightCapFraction,
                    handleOverlaysContent: canvasBackground != nil,
                    bottomSafeAreaMode: safeAreaMode,
                    bottomSafeAreaInset: bottomInset,
                    animateContentHeight: canvasBackground == nil && animateContentHeight,
                    prioritizesDragOverScrolling: keyboardScrollsContent,
                    scrollsEntireSurface: keyboardScrollsContent,
                    entireSurfaceScrollingEnabled: keyboardInset > 0,
                    minimumSurfaceTop: outsideCloseMinimumSurfaceTop
                ),
                // Keep this wrapper mounted while the field is focused. Swapping
                // it in when the keyboard appears recreates the TextField and
                // immediately drops first responder.
                scrollable: keyboardScrollsContent,
                onDismiss: onDismiss,
                content: content,
                cardBackground: canvasBackground.map { AnyView(CampaignCanvasBackgroundView(paint: $0)) },
                viewportOverlay: outsideCanvasClose
            )
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: keyboard.animationDuration), value: keyboardInset)
        }
        .ignoresSafeArea()
    }

    private var outsideCanvasClose: ((CGRect, CGSize) -> AnyView)? {
        if let close = separateClose, close.placement?.mode == .outside {
            return { bounds, viewport in
                AnyView(CanvasNudgeCloseOverlay(
                    config: close, container: bounds, viewport: viewport,
                    safeAreaInsets: surveyWindowSafeAreaInsets, isBottomSheet: true, action: onDismiss))
            }
        }
        return nil
    }

    private var outsideCloseMinimumSurfaceTop: CGFloat {
        guard let close = separateClose,
              let placement = close.placement,
              placement.mode == .outside
        else { return 0 }
        return surveyWindowSafeAreaInsets.top
            + placement.gap
            + max(44, close.diameter)
    }
}

private func canvasSurveySheetBackground(_ survey: SurveyConfigModel) -> CampaignCanvasPaint? {
    guard let canvasSurvey = survey.canvasSurvey else { return nil }
    return canvasSurvey.welcomeDocument?.sharedUi.background
        ?? canvasSurvey.scenesByBlockId.keys.sorted().compactMap {
            canvasSurvey.scenesByBlockId[$0]?.sharedUi.background
        }.first
}

@MainActor
private struct DialogContainer<Content: View>: View {
    let dialog: DialogProps
    let background: Color
    let keyboardScrollsContent: Bool
    let separateClose: NudgeCloseButtonConfig?
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @StateObject private var keyboard = SurveyKeyboardObserver()

    // Blocks the first-frame backdrop tap from closing the survey before the
    // CTA Buttons' gesture recognisers are interactive.
    @State private var armed = false

    var body: some View {
        GeometryReader { geo in
            // SwiftUI can change GeometryReader's proposed height when the
            // keyboard appears even when this view ignores the keyboard safe
            // area. Window bounds remain stable for the full presentation.
            let windowFrame = surveyWindowFrame
            let stableViewport = windowFrame.size
            let hostFrame = geo.frame(in: .global)
            let keyboardInset = keyboard.bottomInset(overlapping: windowFrame)
            let outsideExtent = outsideCloseExtent
            let topChrome = outsideCloseEdge == .top ? outsideExtent : 0
            let bottomChrome = outsideCloseEdge == .bottom ? outsideExtent : 0
            let dialogMaxHeight = max(
                0,
                geo.size.height - keyboardInset - topChrome - bottomChrome
            )
            ZStack {
                (Color(hex: dialog.backdropColorHex) ?? Color.black.opacity(dialog.backdropOpacity))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if armed && dialog.backdropDismissible { onDismiss() }
                    }

                if keyboardScrollsContent {
                    content()
                        .environment(\.canvasSurveyDialogPresentation, CanvasSurveyDialogPresentation(
                            viewport: stableViewport,
                            keyboardInset: keyboardInset,
                            topChrome: topChrome,
                            bottomChrome: bottomChrome,
                            cornerRadius: CGFloat(dialog.cornerRadius),
                            close: separateClose,
                            animation: keyboard.animation
                        ))
                } else {
                    dialogSurface(
                        width: dialogWidth(geo: geo),
                        maxHeight: outsideCloseEdge != nil || keyboardInset > 0
                            ? dialogMaxHeight : nil
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, topChrome)
                    .padding(.bottom, bottomChrome + keyboardInset)
                }
            }
            // GeometryReader places fixed-size children from its top-leading
            // origin. Pinning this ZStack to window bounds prevents SwiftUI's
            // keyboard-adjusted parent proposal from moving or resizing it.
            .frame(
                width: stableViewport.width,
                height: stableViewport.height,
                alignment: .topLeading
            )
            // The host can begin below the status-bar safe area. Move the
            // stable window layer back to the window origin before centering
            // the dialog inside it.
            .offset(
                x: windowFrame.minX - hostFrame.minX,
                y: windowFrame.minY - hostFrame.minY
            )
            .overlayPreferenceValue(NudgeCloseContainerBoundsKey.self) { anchor in
                if !keyboardScrollsContent, let anchor, let close = separateClose, close.placement?.mode == .outside {
                    CanvasNudgeCloseOverlay(
                        config: close, container: geo[anchor], viewport: stableViewport,
                        safeAreaInsets: .zero, isBottomSheet: false, action: onDismiss)

                }
            }
            .animation(keyboardScrollsContent ? nil : keyboard.animation, value: keyboardInset)
            .task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                armed = true
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func dialogWidth(geo: GeometryProxy) -> CGFloat {
        geo.size.width - 32
    }

    private var outsideCloseEdge: NudgeCloseButtonPlacement.Vertical? {
        guard let placement = separateClose?.placement, placement.mode == .outside else {
            return nil
        }
        return placement.vertical
    }

    private var outsideCloseExtent: CGFloat {
        guard let close = separateClose,
              let placement = close.placement,
              placement.mode == .outside
        else { return 0 }
        return placement.gap + max(44, close.diameter)
    }

    @ViewBuilder
    private func dialogSurface(width: CGFloat, maxHeight: CGFloat?) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(dialog.cornerRadius))
        Group {
            if let maxHeight {
                ContentSizedScrollView(maxHeight: maxHeight) {
                    content()
                }
            } else {
                content()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: width)
        .background(shape.fill(background))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture {}
        .anchorPreference(key: NudgeCloseContainerBoundsKey.self, value: .bounds) {
            separateClose?.placement?.mode != .outside ? nil : $0
        }
    }
}

/// The stage uses the full window for fitting; the keyboard only changes its
/// presentation viewport. Passing this down avoids measuring a ScrollView's
/// proposed size or retaining the dimensions of an earlier survey scene.
struct CanvasSurveyDialogPresentation {
    let viewport: CGSize
    let keyboardInset: CGFloat
    let topChrome: CGFloat
    let bottomChrome: CGFloat
    let cornerRadius: CGFloat
    let close: NudgeCloseButtonConfig?
    let animation: Animation

    var availableWidth: CGFloat { max(0, viewport.width - 32) }
}

private struct CanvasSurveyDialogPresentationKey: EnvironmentKey {
    static var defaultValue: CanvasSurveyDialogPresentation? { nil }
}

extension EnvironmentValues {
    var canvasSurveyDialogPresentation: CanvasSurveyDialogPresentation? {
        get { self[CanvasSurveyDialogPresentationKey.self] }
        set { self[CanvasSurveyDialogPresentationKey.self] = newValue }
    }
}

/// Mirrors Android's centered IME-padded host and height-capped scroll surface.
/// Interpolate one inset, then derive both the frame and position from that same
/// value. The authored stage retains its explicit size throughout the animation.
struct CanvasSurveyDialogKeyboardLayout: AnimatableModifier {
    let presentation: CanvasSurveyDialogPresentation
    let surfaceSize: CGSize
    let onClose: () -> Void
    // SwiftUI interpolates this value through Animatable's nonisolated contract.
    // It is value-only state; view construction remains on the main actor.
    nonisolated var keyboardInset: CGFloat

    nonisolated var animatableData: CGFloat {
        get { keyboardInset }
        set { keyboardInset = newValue }
    }

    func body(content: Content) -> some View {
        let availableHeight = max(0, presentation.viewport.height - keyboardInset)
        let surfaceHeight = min(surfaceSize.height, max(
            0, availableHeight - presentation.topChrome - presentation.bottomChrome
        ))
        let dialogHeight = surfaceHeight + presentation.topChrome + presentation.bottomChrome
        let top = max(0, (availableHeight - dialogHeight) / 2)
        let width = presentation.availableWidth

        return scrollSurface(content: content, height: surfaceHeight)
            .frame(width: width, height: surfaceHeight, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: presentation.cornerRadius))
            .contentShape(Rectangle())
            .onTapGesture {}
            .padding(.top, presentation.topChrome)
            .padding(.bottom, presentation.bottomChrome)
            .overlay(alignment: .topLeading) {
                if let close = presentation.close, close.placement?.mode == .outside {
                    CanvasNudgeCloseOverlay(
                        config: close,
                        container: CGRect(
                            x: 0, y: presentation.topChrome,
                            width: width, height: surfaceHeight
                        ),
                        viewport: CGSize(width: width, height: dialogHeight),
                        safeAreaInsets: .zero,
                        isBottomSheet: false,
                        action: onClose
                    )
                }
            }
            .offset(y: top)
            .frame(
                width: presentation.viewport.width,
                height: presentation.viewport.height,
                alignment: .top
            )
            // Keep the full-window host stationary; only the dialog inside it
            // moves. Its safe-area calculation must not follow that movement.
            .ignoresSafeArea()
            // This modifier already supplies each animation frame. Neither the
            // scroll view nor its canvas should start another layout animation.
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }

    @ViewBuilder
    private func scrollSurface(content: Content, height: CGFloat) -> some View {
        let scroll = ScrollView(.vertical, showsIndicators: false) {
            content
                .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .topLeading)
                .frame(width: presentation.availableWidth, alignment: .center)
                .background(CanvasSurveyScrollBounds())
        }

        if #available(iOS 16, *) {
            scroll
                .scrollDisabled(surfaceSize.height <= height)
                .scrollDismissesKeyboard(.never)
        } else {
            scroll
        }
    }
}

/// SwiftUI's basedOnSize policy still bounces when content overflows. Configure
/// only this dialog's enclosing scroll view so dragging stops at its real ends.
private struct CanvasSurveyScrollBounds: UIViewRepresentable {
    func makeUIView(context: Context) -> ScrollBoundsView {
        let view = ScrollBoundsView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ScrollBoundsView, context: Context) {
        uiView.disableBounce()
        // SwiftUI can update the enclosing scroll view later in this pass.
        DispatchQueue.main.async { [weak uiView] in uiView?.disableBounce() }
    }

    final class ScrollBoundsView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            disableBounce()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            disableBounce()
        }

        func disableBounce() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.bounces = false
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

@MainActor private var surveyWindowFrame: CGRect {
    guard let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive })?
        .windows.first(where: \.isKeyWindow)
    else { return UIScreen.main.bounds }
    return window.convert(window.bounds, to: nil)
}

@MainActor private var surveyWindowSafeAreaInsets: UIEdgeInsets {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })?
        .windows.first(where: \.isKeyWindow)?
        .safeAreaInsets ?? .zero
}

@available(iOS 16, *)
private struct HeightCappedLayout: Layout {
    var maxHeight: CGFloat

    // Interpolate the scroll viewport alongside the dialog's keyboard padding.
    var animatableData: CGFloat {
        get { maxHeight }
        set { maxHeight = newValue }
    }

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
        // `HeightCappedLayout` needs iOS 16 (the `Layout` protocol); below that,
        // `.frame(maxHeight:)` on the scroll view is the closest built-in equivalent.
        if #available(iOS 16, *) {
            HeightCappedLayout(maxHeight: maxHeight) {
                ScrollView(.vertical, showsIndicators: false) {
                    content()
                }
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                content()
            }
            .frame(maxHeight: maxHeight)
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
                            .font(surveyFont(size: 14, weight: 600))
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
                SDKInstance.shared.reportSurveyStartClicked()
                welcomeDone = true
            } label: {
                Text(cta.startLabel)
                    .font(surveyFont(size: 15, weight: cta.fontWeight))
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
                    .font(surveyFont(size: 11, weight: 600))
                    .foregroundColor(SurveyTokens.textTertiary)
            }
            if timerCfg.enabled && timerCfg.timeLimitSeconds > 0 {
                TimerChip(remainingSecs: remainingSecs, warningAtSecs: timerCfg.warningAtSeconds, accent: accent)
            }
            if showCloseButton && survey.settings.display.dismissible {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(surveyFont(size: 14, weight: 600))
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
        ContentSizedScrollView(maxHeight: scrollMaxHeight()) {
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

    private func scrollMaxHeight() -> CGFloat {
        // Screen-relative budget so the surrounding SurveyBody never exceeds
        // the dialog/sheet on small phones.
        let screen = UIScreen.main.bounds.height
        return min(screen * 0.6, screen - 240)
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
                SDKInstance.shared.reportSurveyStartClicked()
                vm.advance()
            } label: {
                Text(cta.startLabel)
                    .font(surveyFont(size: 15, weight: cta.fontWeight))
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
                        .font(surveyFont(size: 14, weight: cta.fontWeight))
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
            .font(surveyFont(size: 11, weight: 600))
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
                .font(surveyFont(size: 10.5, weight: 700))
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

    init(media: BlockMedia) {
        DigiaImagePipeline.configureIfNeeded()
        self.media = media
    }

    private var contentMode: ContentMode {
        switch media.boxFit {
        case "contain": return .fit
        default: return .fill
        }
    }

    var body: some View {
        if media.hasUrl, let url = URL(string: media.url) {
            WebImage(url: url) { image in
                if media.boxFit == "fill" {
                    image.resizable()
                } else {
                    image.resizable().aspectRatio(contentMode: contentMode)
                }
            } placeholder: {
                ZStack {
                    SurveyTokens.surfaceSunken
                    BlurHashPlaceholderView(placeholder: media.placeholder)
                }
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
                .font(surveyFont(size: 14, weight: cta.fontWeight))
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
                .font(surveyFont(size: 14, weight: cta.fontWeight))
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
