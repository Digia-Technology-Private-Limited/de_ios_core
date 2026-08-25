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
                // Full-bleed, so `geo.size` below is the device's screen and not whatever region
                // the host app happened to give `DigiaHost`. The window is then placed inside the
                // real safe area explicitly, from `activeFloaterWindowSafeAreaInsets`. Letting the
                // container decide instead is what left a small window inset twice over — once by
                // the host's own safe area and again by its margins — so it floated far further in
                // from the top and bottom edges than the author had asked for.
                .ignoresSafeArea()
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
/// Flutter's `Curves.easeInOutQuart`, the curve `pip_renderer.dart` grows and collapses on — and
/// the one the PiP's own expand already uses here. The story floater's hero shares it so the two
/// floaters expand identically.
private func storyEaseInOutQuart(duration: Double) -> Animation {
    .timingCurve(0.77, 0, 0.175, 1, duration: duration)
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
    /// 0 is "still the window", 1 is "full screen". One value for both directions, because the two
    /// are the same journey — a collapse interrupted by a re-open resumes from where it had got to
    /// rather than snapping back to the window first.
    @State private var storyPhase: CGFloat = 0
    /// Outlives `orchestrator.storyOpen`: the orchestrator flips that the instant the user closes,
    /// but the cover has to stay presented until the collapse has finished running.
    @State private var viewerMounted = false
    /// How far the story's own content has faded up, once the cover is presented.
    ///
    /// Separate from `storyPhase` because on iOS the two do not overlap. The box growing and the
    /// story fading are one continuous motion on Android, where the story is drawn *inside* the
    /// growing box and clipped by it. That is not safely reproducible here: a `fullScreenCover`
    /// lays its content out in safe-area coordinates, so an aperture clipped to a rect measured in
    /// the overlay's screen coordinates would sit a status bar off — and the alternative, dropping
    /// the cover and rendering inline, would take the viewer's own safe-area handling with it.
    /// So the box grows, and the story fades up over it as it lands. No pop, and no clip to
    /// misalign.
    @State private var contentFade: CGFloat = 0
    /// The screen the viewer fills, and the window's rect within it, captured from the layout so
    /// the cover — which is presented outside this `GeometryReader` — can still run a hero.
    @State private var coverScreenSize: CGSize = .zero
    @State private var coverWindowRect: CGRect = .zero

    private var config: FloaterStoryConfig { state.config }
    private var isDark: Bool { canvasTheme.isDark(colorScheme) }

    var body: some View {
        GeometryReader { geo in
            // The device's screen and the device's insets, from the same window — never this
            // reader's own numbers. A `GeometryReader` at the root of a hosting controller reports
            // a size that has *already* had the safe area carved out of it; subtracting real
            // insets from that again is what inset the window twice over, which on a small window
            // is most of what you see.
            let deviceGeometry = activeFloaterWindowGeometry
            let screenSize = deviceGeometry.bounds.size
            let safe = deviceGeometry.safeArea
            // In the device's own coordinates, so it means the same thing wherever the host app
            // put `DigiaHost`.
            let resting = storyWindowRect(
                config: config, screenSize: screenSize, safeInsets: safe,
                dragFraction: orchestrator.dragFraction
            )
            let delta = isDragging ? dragTranslation : settleResidual
            // This reader's offset within the screen. Zero in the ordinary case — the view above
            // is full-bleed — but subtracted rather than assumed, so a host that nests `DigiaHost`
            // somewhere smaller still draws the window where the screen coordinates say it is
            // rather than that much further in again.
            let globalOrigin = geo.frame(in: .global).origin
            // Deliberately unclamped during an active drag — a fast flick can carry the
            // box past the safe area while the finger is still moving, the same
            // rubber-band feel the PiP has. `commitDrag` is what snaps it back.
            let left = resting.minX - globalOrigin.x
                + delta.width + flyOffsetFraction.width * resting.width
            let top = resting.minY - globalOrigin.y
                + delta.height + flyOffsetFraction.height * resting.height
            let windowAlpha = floaterStoryWindowAlpha(
                type: orchestrator.storyOpen ? config.behavior.expandTransition.type
                                             : config.behavior.collapseTransition.type,
                phase: storyPhase
            )
            // `nil` while the story is open, for the same reason the window itself is not
            // drawn then: a host's `hitTest` trusts this rect to claim touches, and a rect
            // published for a window that is not on screen would claim them for nothing.
            // (While the story is up, `Digia.hasActiveOverlay` is what claims the screen.)
            let publishedActiveRect: CGRect? =
                orchestrator.storyOpen
                ? nil
                : CGRect(
                    x: left + globalOrigin.x, y: top + globalOrigin.y,
                    width: resting.width, height: resting.height
                )
            // The window's box in this reader's own space, which is what the shield below and the
            // hero's growing box are both positioned in.
            let localWindowRect = CGRect(
                x: left, y: top, width: resting.width, height: resting.height
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
                // ── the hero's growing box ──
                //
                // A plain rect travelling from the window to the screen, in the story's own
                // colour. It carries no content, which is the point: the PiP hides its expanded
                // tree for the length of the grow because content stretched across a changing box
                // reads as a glitch, and a story — video, canvas stage, chrome — is far more of it
                // than a nudge tree. First in the stack, so the window sits over it and can
                // cross-fade out against it rather than vanishing.
                if config.behavior.expandTransition.type == .hero
                    || config.behavior.collapseTransition.type == .hero,
                   storyPhase > 0, storyPhase < 1 {
                    let heroRect = floaterStoryHeroRect(
                        window: localWindowRect, screen: screenSize, phase: storyPhase
                    )
                    RoundedRectangle(
                        cornerRadius: floaterStoryHeroCornerRadius(
                            windowRadius: config.window.cornerRadiusDp, phase: storyPhase
                        )
                    )
                    .fill(Color.black)
                    .frame(width: heroRect.width, height: heroRect.height)
                    .position(x: heroRect.midX, y: heroRect.midY)
                }

                // Drag-to-reposition and tap-to-open, through the PiP's own UIKit shield:
                // a SwiftUI `DragGesture` re-evaluates this whole body on every touch-move
                // and cannot keep pace with the finger.
                if !orchestrator.storyOpen {
                    let activeRect = localWindowRect
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
                    // Fills this reader rather than the device screen: the rect it hit-tests
                    // against is in this reader's space, so the two have to be measured the same
                    // way or a nested host would offset every touch.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if windowAlpha > 0 {
                    windowBox(width: resting.width)
                        .frame(width: resting.width, height: resting.height, alignment: .topLeading)
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
                                // Decoration, never a target: a stroked `Shape` hit-tests
                                // its own stroked path, so an authored border would quietly
                                // eat the ring of touches around the window's edge instead
                                // of letting them reach the shield that opens the story.
                                .allowsHitTesting(false)
                        )
                        .overlay(alignment: .topTrailing) {
                            if config.controls.showClose { closeButton }
                        }
                        .position(x: left + resting.width / 2, y: top + resting.height / 2)
                        // The window's own entry/exit alpha, times how far the story has covered
                        // it. Keyed on the phase rather than on `storyOpen` because a hero grows
                        // *out of* this box: cutting it the instant the flag flips would leave the
                        // story rising from a hole.
                        .opacity(alpha * windowAlpha)
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
            .onAppear {
                coverScreenSize = screenSize
                coverWindowRect = publishedActiveRect ?? localWindowRect
            }
            .onChange(of: screenSize) { coverScreenSize = $0 }
            .onChange(of: resting) { _ in
                // Where the window is *drawn*, drag included — a hero has to start from the box the
                // user tapped, not from where it would have been had they never moved it. In screen
                // coordinates, because the cover it feeds is presented against the screen.
                coverWindowRect = publishedActiveRect ?? localWindowRect
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
        .onChange(of: orchestrator.storyOpen) { open in runStoryTransition(opening: open) }
        // The viewer is presented over everything, at full screen — the same cover a canvas story
        // rail presents, with the same content.
        //
        // Presented on `viewerMounted` rather than on `orchestrator.storyOpen`, because the cover
        // has to outlast the close by exactly the length of the collapse.
        //
        // `fullScreenCover` has one presentation of its own — a slide up from the bottom — and an
        // author who chose `hero` would otherwise get both at once. It is suppressed by toggling
        // `viewerMounted` inside a transaction with `disablesAnimations` set (see
        // `runStoryTransition`), NOT by a `.transaction { }` modifier here: that modifier applies
        // to this whole subtree, so it silently disabled the very `withAnimation` that drives the
        // motion below and left every transition instant.
        .fullScreenCover(
            isPresented: Binding(
                get: { viewerMounted },
                set: { if !$0 { orchestrator.closeStory() } }
            )
        ) {
            storyCover
        }
    }

    /// The story, transformed by however far the expand or collapse has got.
    ///
    /// The backdrop is the load-bearing part. A `fullScreenCover` paints its own opaque background,
    /// and the viewer inside deliberately has no black plate of its own — its media backdrop is
    /// what covers the screen. That is fine at rest and wrong for every frame before it: while the
    /// content is scaled into the window's box, or still below the fold on a slide, the rest of the
    /// screen is the cover's background, which in light mode is **white**. The whole screen flashed
    /// white for the length of every transition.
    ///
    /// So the cover's background is cleared and the host app shows through instead, which is what a
    /// hero wants anyway — the story visibly grows out of the window and over the app. Below 16.4
    /// there is no way to clear it, so an explicit black plate stands in: darker than the app, but
    /// the story's own colour rather than a white flash.
    @ViewBuilder
    private var storyCover: some View {
        let transform = floaterStoryTransform(
            type: orchestrator.storyOpen ? config.behavior.expandTransition.type
                                         : config.behavior.collapseTransition.type,
            phase: storyPhase,
            screen: coverScreenSize
        )
        // A hero resolves to identity: by the time it has presented the viewer, the growing box
        // has already finished the journey.
        let content = storyViewer
            .offset(y: transform.translationY)
            .opacity(transform.alpha * contentFade)
            // Deliberately NOT `.ignoresSafeArea()`. The viewer already decides that for itself,
            // and the split matters: its media backdrop ignores the safe area so the artwork
            // reaches the screen's edges, while the page canvas and the chrome over it stay inside
            // it — which is the contract the dashboard authors against, where a page's box *is* the
            // safe region. Ignoring it out here overrode that and pushed the author's content and
            // the close button under the notch and home indicator.

        if #available(iOS 16.4, *) {
            content.presentationBackground(.clear)
        } else {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
        }
    }

    /// Runs the expand or the collapse, and keeps the cover mounted for as long as it takes.
    ///
    /// The unmount is deferred by the collapse's own duration rather than driven by a completion
    /// handler: `withAnimation`'s completion is not available on every OS this SDK supports, and a
    /// timer that agrees with the animation it accompanies is simpler than one that has to be
    /// cancelled. A re-open inside that window is safe — `viewerMounted` is already true and the
    /// deferred close checks the orchestrator before acting.
    private func runStoryTransition(opening: Bool) {
        if opening {
            let expand = config.behavior.expandTransition
            if expand.isInstant {
                storyPhase = 1
                present(mounted: true)
                return
            }
            withAnimation(storyEaseInOutQuart(duration: expand.duration)) { storyPhase = 1 }
            if expand.type == .hero {
                // The box grows, and the story is presented as it lands and fades up over it —
                // rather than switching on fully formed, which reads as two events where the whole
                // point of the motion is that they are one. The fade overlaps the last of the
                // growth: it starts a little early and runs a little past, so the two motions
                // share a moment instead of queueing.
                let fadeLead = min(0.12, expand.duration * 0.35)
                DispatchQueue.main.asyncAfter(deadline: .now() + expand.duration - fadeLead) {
                    guard orchestrator.storyOpen else { return }
                    contentFade = 0
                    present(mounted: true)
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: fadeLead + 0.1)) { contentFade = 1 }
                    }
                }
            } else {
                // A slide moves the viewer itself, so it has to exist for the whole motion. The
                // story is fully drawn the whole way — it is the story that travels.
                contentFade = 1
                present(mounted: true)
            }
            return
        }
        let collapse = config.behavior.collapseTransition
        if collapse.isInstant {
            storyPhase = 0
            contentFade = 0
            present(mounted: false)
            return
        }
        // Mirror image of the expand: for a hero the story fades out and the box shrinks back to
        // the window behind it; for a slide the viewer itself travels back down.
        if collapse.type == .hero {
            withAnimation(.easeIn(duration: min(0.12, collapse.duration * 0.35))) { contentFade = 0 }
            present(mounted: false)
        }
        withAnimation(storyEaseInOutQuart(duration: collapse.duration)) { storyPhase = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + collapse.duration) {
            // Only if the user has not re-opened it in the meantime.
            if !orchestrator.storyOpen { present(mounted: false) }
        }
    }

    /// Mounts or unmounts the cover without the system's own presentation animation.
    private func present(mounted: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { viewerMounted = mounted }
    }

    /// The author's canvas, scaled to the window.
    ///
    /// Scaled rather than fitted: the window's box IS the canvas's box — the dashboard
    /// derives the window's aspect ratio from it — so the two differ only by the
    /// uniform scale between design units and this device's points. Going through
    /// `CampaignCanvasView` instead would re-fit the canvas against the viewport, which
    /// is the screen rather than this window.
    ///
    /// The width is passed in rather than read from `UIScreen`, and the post-scale
    /// `.frame` is not optional. `scaleEffect` does not change a view's layout size, so
    /// without that frame the stage lays out at its authored size and is *centred*
    /// inside the window's box — which offsets every child's hit region from where it
    /// is drawn, so taps on a button land next to it. This is the same three-modifier
    /// idiom `CampaignCanvasView` uses, for the same reason.
    private func windowBox(width: CGFloat) -> some View {
        let scale = width / max(config.canvas.width, 1)
        return CampaignCanvasStage(
            canvas: config.canvas,
            authoredCornerRadius: 0,
            isDark: isDark,
            showBackground: true,
            onAction: runCanvasAction,
            // Empty canvas falls through to the shield below, which opens the story;
            // a button or tap region on the same canvas still takes its own touch,
            // because children opt into hit testing individually.
            backgroundTakesTouches: false
        )
        .frame(width: config.canvas.width, height: config.canvas.height, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(
            width: config.canvas.width * scale,
            height: config.canvas.height * scale,
            alignment: .topLeading
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
