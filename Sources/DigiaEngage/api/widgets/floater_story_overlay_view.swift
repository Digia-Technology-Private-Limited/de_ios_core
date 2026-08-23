import Foundation
import SwiftUI
import UIKit

// The story floater's window: a small canvas floating over the host app, and the
// full-screen story a tap on it opens.
//
// Mounted as a plain SwiftUI sibling in `DigiaHost`'s own `ZStack`, beside
// `FloaterOverlayView`. Its own view rather than a branch inside that one: the two
// floater subtypes are separate campaigns with separate orchestrators, and neither knows
// anything about the other's state.
//
// The drag shield, the settle spring and the entry/exit curves below are the PiP's —
// `FloaterCollapsedInteractionView` is shared outright, and the constants are copied with
// the same values, because the gesture is the same gesture. What is NOT here is
// everything only a media window has: no grow-to-full-screen transition, no `AVPlayer`,
// no playback chrome, and so no second geometry. The window's box never changes size; the
// story arrives as a `fullScreenCover` over it, which is what lets the viewer be the very
// same one a canvas story rail opens.

@MainActor
struct FloaterStoryOverlayView: View {
    @ObservedObject private var orchestrator = SDKInstance.shared.floaterStoryOrchestrator

    var body: some View {
        if let state = orchestrator.state {
            FloaterStorySessionView(state: state, orchestrator: orchestrator)
                .id(state.token)
        }
    }
}

/// The PiP's settle spring, in the same physical units.
private let storySettleSpring = Animation.interpolatingSpring(mass: 1, stiffness: 210, damping: 24)

private func storyEaseOutBack(duration: Double) -> Animation {
    .timingCurve(0.34, 1.56, 0.64, 1, duration: duration)
}
private func storyEaseOutCubic(duration: Double) -> Animation {
    .timingCurve(0.215, 0.61, 0.355, 1, duration: duration)
}
private func storyEaseIn(duration: Double) -> Animation {
    .timingCurve(0.42, 0, 1, 1, duration: duration)
}

@MainActor
private struct FloaterStorySessionView: View {
    let state: ActiveFloaterStoryState
    @ObservedObject var orchestrator: FloaterStoryOrchestrator
    @ObservedObject private var canvasTheme = CampaignCanvasTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false
    @State private var settleResidual: CGSize = .zero
    @State private var flyOffsetFraction: CGSize = .zero
    @State private var alpha: Double = 1

    private var config: FloaterStoryConfig { state.config }
    private var isDark: Bool { canvasTheme.isDark(colorScheme) }

    var body: some View {
        GeometryReader { geo in
            let screenSize = geo.size
            let safe = geo.safeAreaInsets
            let resting = storyWindowRect(
                config: config, screenSize: screenSize, safeInsets: safe,
                dragFraction: orchestrator.dragFraction
            )
            let delta = isDragging ? dragTranslation : settleResidual
            // Deliberately unclamped during an active drag — a fast flick can carry the
            // box past the safe area while the finger is still moving, the same
            // rubber-band feel the PiP has. `commitDrag` is what snaps it back.
            let left = resting.minX + delta.width + flyOffsetFraction.width * resting.width
            let top = resting.minY + delta.height + flyOffsetFraction.height * resting.height
            let globalOrigin = geo.frame(in: .global).origin
            // `nil` while the story is open, for the same reason the window itself is not
            // drawn then: a host's `hitTest` trusts this rect to claim touches, and a rect
            // published for a window that is not on screen would claim them for nothing.
            let publishedActiveRect: CGRect? =
                orchestrator.storyOpen
                ? nil
                : CGRect(
                    x: left + globalOrigin.x, y: top + globalOrigin.y,
                    width: resting.width, height: resting.height
                )

            // Nothing of the window is drawn while the story is open. `fullScreenCover`
            // already covers this view, so on iOS this is not the paint-order fix it is on
            // Flutter (where the renderer's overlay entry sits above the story's own
            // route) — but a window still mounted underneath keeps its canvas, and its
            // touch shield, live behind a full-screen story. The three SDKs agree that
            // opening the story replaces the window, so the rule is stated the same way in
            // each. The `@State` above stays put, so the window returns exactly where the
            // user left it.
            ZStack {
                // Drag-to-reposition and tap-to-open, through the PiP's own UIKit shield:
                // a SwiftUI `DragGesture` re-evaluates this whole body on every touch-move
                // and cannot keep pace with the finger.
                if !orchestrator.storyOpen {
                    let activeRect = CGRect(
                        x: left, y: top, width: resting.width, height: resting.height
                    )
                    FloaterCollapsedInteractionView(
                        activeRect: activeRect,
                        draggable: config.controls.draggable,
                        tapExpands: true,
                        closing: orchestrator.closing,
                        onDragChanged: handleDragChanged,
                        onDragEnded: { translation, predicted in
                            handleDragEnded(
                                translation: translation,
                                predictedEndTranslation: predicted,
                                resting: resting,
                                screenSize: screenSize,
                                safe: safe
                            )
                        },
                        onTap: openStory,
                        chromeButtonBounds: closeButtonRects(activeRect: activeRect)
                    )
                    .frame(width: screenSize.width, height: screenSize.height)
                }

                if !orchestrator.storyOpen {
                    windowBox
                        .frame(width: resting.width, height: resting.height)
                        .clipShape(RoundedRectangle(cornerRadius: config.window.cornerRadiusDp))
                        .shadow(
                            color: config.window.shadow ? Color.black.opacity(0.45) : .clear,
                            radius: config.window.shadow ? 12 : 0,
                            x: 0,
                            y: config.window.shadow ? 8 : 0
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: config.window.cornerRadiusDp)
                                .stroke(
                                    config.window.borderColor.map {
                                        canvasTheme.color($0, isDark: isDark)
                                    } ?? .white,
                                    lineWidth: config.window.borderWidthDp
                                )
                        )
                        .overlay(alignment: .topTrailing) {
                            if config.controls.showClose { closeButton }
                        }
                        .position(x: left + resting.width / 2, y: top + resting.height / 2)
                        .opacity(alpha)
                }
            }
            // Publishes this window's real on-screen frame so an RN/UIKit host's
            // `hitTest` can tell a touch on it apart from empty space. Computed from
            // `left`/`top` directly rather than read back after `.position(...)`, which
            // reports the whole available space — see the PiP's own note.
            .onAppear {
                DispatchQueue.main.async { orchestrator.activeRect = publishedActiveRect }
            }
            .onChange(of: publishedActiveRect) { newRect in
                orchestrator.activeRect = newRect
            }
        }
        .onAppear {
            runEntryAnimation()
            // The impression is the first painted frame, not the routing decision.
            orchestrator.markVisible(token: state.token)
        }
        .onChange(of: orchestrator.closing) { closing in
            if closing { runExitAnimation() }
        }
        .onDisappear { orchestrator.activeRect = nil }
        // The viewer is presented over everything, at full screen — the same cover a
        // canvas story rail presents, with the same content.
        .fullScreenCover(
            isPresented: Binding(
                get: { orchestrator.storyOpen },
                set: { if !$0 { orchestrator.closeStory() } }
            )
        ) {
            storyViewer
        }
    }

    /// The author's canvas, scaled to the window.
    ///
    /// Scaled rather than fitted: the window's box IS the canvas's box — the dashboard
    /// derives the window's aspect ratio from it — so the two can only differ by the
    /// uniform scale between design units and this device's points. Going through
    /// `CampaignCanvasView` instead would re-fit the canvas against the viewport, which
    /// is the screen rather than this window.
    private var windowBox: some View {
        CampaignCanvasStage(
            canvas: config.canvas,
            authoredCornerRadius: 0,
            isDark: isDark,
            showBackground: true,
            onAction: runCanvasAction
        )
        .frame(width: config.canvas.width, height: config.canvas.height, alignment: .topLeading)
        .scaleEffect(
            storyWindowWidth(screenWidth: UIScreen.main.bounds.width) / max(config.canvas.width, 1),
            anchor: .topLeading
        )
        .environment(\.digiaVariables, state.variableContext)
    }

    @ViewBuilder
    private var storyViewer: some View {
        if case .story(
            _, let pages, _, _, _, _, _, let restartOnCompleted, let startMuted, let chrome
        ) = config.story {
            CanvasStoryViewer(
                pages: pages,
                chrome: chrome,
                initialIndex: 0,
                restartOnCompleted: restartOnCompleted,
                startMuted: startMuted,
                isDark: isDark,
                onAction: runCanvasAction,
                onDismiss: { orchestrator.closeStory() }
            )
            .environment(\.digiaVariables, state.variableContext)
        }
    }

    /// The built-in ×, pinned top-right.
    ///
    /// Always that corner, like the PiP's: on a box this small there is nowhere else for
    /// it to go, and an affordance that moves per campaign is one the user has to re-find.
    private var closeButton: some View {
        Button {
            SDKInstance.shared.reportFloaterStoryClicked(
                elementId: "floater_close", actionType: "close", ctaRole: "secondary"
            )
            orchestrator.dismiss(.userClose)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: config.controls.iconSize * 0.6, weight: .semibold))
                .foregroundColor(.white)
                .frame(
                    width: config.controls.iconSize * 1.6,
                    height: config.controls.iconSize * 1.6
                )
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
        }
        .padding(.top, config.controls.margin.top)
        .padding(.trailing, config.controls.margin.right)
    }

    // MARK: - Interaction

    private func openStory() {
        guard !orchestrator.storyOpen, !orchestrator.closing else { return }
        SDKInstance.shared.reportFloaterStoryClicked(
            elementId: "floater_window", actionType: "show_story", ctaRole: "primary"
        )
        orchestrator.openStory()
    }

    /// Runs an authored action from the window's canvas or from inside a story.
    ///
    /// `Action.showStory` never reaches here: the canvas stage routes it to a rail on its
    /// own canvas, and this campaign's window carries none — so a tap on the window is
    /// what opens the story instead.
    private func runCanvasAction(_ request: CampaignCanvasActionRequest) {
        SDKInstance.shared.runFloaterStoryAction(state: state, request: request)
    }

    private func handleDragChanged(_ translation: CGSize) {
        guard config.controls.draggable, !orchestrator.closing, !orchestrator.storyOpen
        else { return }
        if !isDragging {
            guard hypot(translation.width, translation.height) > 6 else { return }
            // A new touch beats an in-flight spring: grabbing the window mid-bounce must
            // take control immediately, not fight it.
            isDragging = true
            settleResidual = .zero
        }
        dragTranslation = translation
    }

    private func handleDragEnded(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        resting: CGRect,
        screenSize: CGSize,
        safe: EdgeInsets
    ) {
        guard !orchestrator.closing else { return }
        guard isDragging, hypot(translation.width, translation.height) > 6,
              config.controls.draggable
        else {
            isDragging = false
            dragTranslation = .zero
            return
        }

        let margin = config.window.margin
        let minX = safe.leading + margin.left
        let maxX = screenSize.width - safe.trailing - margin.right - resting.width
        let minY = safe.top + margin.top
        let maxY = screenSize.height - safe.bottom - margin.bottom - resting.height
        let spanX = maxX - minX
        let spanY = maxY - minY

        let visualLeft = resting.minX + translation.width
        let visualTop = resting.minY + translation.height

        var fx: CGFloat = spanX <= 0 ? 0 : ((visualLeft - minX) / spanX).clampedToStoryRange(0, 1)
        var fy: CGFloat = spanY <= 0 ? 0 : ((visualTop - minY) / spanY).clampedToStoryRange(0, 1)
        if config.controls.snapToCorner {
            // The *projected* end of the flick, not where the finger left off — a quick
            // flick often releases before the window visually crosses the half-way line.
            let projectedLeft = resting.minX + predictedEndTranslation.width
            let projectedTop = resting.minY + predictedEndTranslation.height
            let projectedFx: CGFloat =
                spanX <= 0 ? 0 : ((projectedLeft - minX) / spanX).clampedToStoryRange(0, 1)
            let projectedFy: CGFloat =
                spanY <= 0 ? 0 : ((projectedTop - minY) / spanY).clampedToStoryRange(0, 1)
            fx = projectedFx >= 0.5 ? 1 : 0
            fy = projectedFy >= 0.5 ? 1 : 0
        }
        let landingX = spanX <= 0 ? minX : minX + spanX * fx
        let landingY = spanY <= 0 ? minY : minY + spanY * fy

        orchestrator.moveTo(FloaterFraction(x: fx, y: fy))
        isDragging = false
        dragTranslation = .zero
        // The resting rect has just jumped to the corner, so carry the visual position
        // across as a residual and let the spring pull it in — otherwise the window
        // teleports and only then animates.
        settleResidual = CGSize(width: visualLeft - landingX, height: visualTop - landingY)
        withAnimation(storySettleSpring) { settleResidual = .zero }
    }

    // MARK: - Entry/exit

    private func runEntryAnimation() {
        let entry = config.window.entryAnimation
        guard entry.type != .appear else {
            alpha = 1
            return
        }
        alpha = 0
        let flies = entry.type == .flyIn
        flyOffsetFraction = flies ? storyFlyOffset(entry.from) : .zero
        let duration = Double(entry.durationMs) / 1000
        // Arriving overshoots and settles, matching how releasing a drag feels.
        withAnimation(flies ? storyEaseOutBack(duration: duration) : storyEaseOutCubic(duration: duration)) {
            alpha = 1
            flyOffsetFraction = .zero
        }
    }

    private func runExitAnimation() {
        let exit = config.window.exitAnimation
        guard exit.type != .none else { return }
        let flies = exit.type == .flyOut
        let duration = Double(exit.durationMs) / 1000
        // Leaving accelerates away: an overshoot on exit reads as a glitch, since there
        // is nothing left on screen for it to settle against.
        withAnimation(flies ? storyEaseOutCubic(duration: duration) : storyEaseIn(duration: duration)) {
            alpha = 0
            if flies { flyOffsetFraction = storyFlyOffset(exit.to) }
        }
    }

    /// One window-length in the given direction, as a fraction of the window's own size.
    private func storyFlyOffset(_ direction: FloaterFlyDirection) -> CGSize {
        switch direction {
        case .left: return CGSize(width: -1.4, height: 0)
        case .right: return CGSize(width: 1.4, height: 0)
        case .top: return CGSize(width: 0, height: -1.4)
        case .bottom: return CGSize(width: 0, height: 1.4)
        }
    }

    /// The × button's box, so the shield's tap does not also fire when the × is tapped.
    private func closeButtonRects(activeRect: CGRect) -> [CGRect] {
        guard config.controls.showClose else { return [] }
        let size = config.controls.iconSize * 1.6
        return [
            CGRect(
                x: activeRect.maxX - config.controls.margin.right - size,
                y: activeRect.minY + config.controls.margin.top,
                width: size, height: size
            )
        ]
    }

    private func storyWindowWidth(screenWidth: CGFloat) -> CGFloat {
        screenWidth * config.window.widthFraction
    }
}

/// The window's rect for the given screen size.
///
/// Width is a fraction of the screen and height follows the authored aspect ratio — which
/// the dashboard derives from the window canvas's own shape, so the box is always the box
/// the author drew. Margins apply inside the safe area, so a top-corner window clears the
/// status bar and notch and a bottom one clears the home indicator.
private func storyWindowRect(
    config: FloaterStoryConfig, screenSize: CGSize, safeInsets: EdgeInsets,
    dragFraction: FloaterFraction?
) -> CGRect {
    let width = screenSize.width * config.window.widthFraction
    let height = width / config.window.aspectRatio
    let margin = config.window.margin

    let minX = safeInsets.leading + margin.left
    let maxX = screenSize.width - safeInsets.trailing - margin.right - width
    let minY = safeInsets.top + margin.top
    let maxY = screenSize.height - safeInsets.bottom - margin.bottom - height

    let left: CGFloat
    let top: CGFloat
    if let drag = dragFraction {
        left = minX + (maxX - minX) * drag.x
        top = minY + (maxY - minY) * drag.y
    } else {
        left = config.window.position.isRight ? maxX : minX
        top = config.window.position.isBottom ? maxY : minY
    }
    return CGRect(
        x: left.clampedToStoryRange(minX, maxX < minX ? minX : maxX),
        y: top.clampedToStoryRange(minY, maxY < minY ? minY : maxY),
        width: width, height: height
    )
}

extension Comparable {
    fileprivate func clampedToStoryRange(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}
