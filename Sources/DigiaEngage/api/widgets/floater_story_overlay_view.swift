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
// The window itself — drag, fling, snap, entry/exit, shadow — is the shared `FloatingWindow`
// (`api/internal/floating/FloatingWindow.swift`), the same one the PiP floats in. What this
// surface passes in is its own: the window's size, its content (the author's canvas, and the
// story a tap opens), its × and what each reports. The story uses the same hero shape as the
// PiP's grow: mount the viewer first, clip it through the floating window's aperture, then grow
// that aperture to the screen.

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

@MainActor
private struct FloaterStorySessionView: View {
    let state: ActiveFloaterStoryState
    @ObservedObject var orchestrator: FloaterStoryOrchestrator
    @ObservedObject private var canvasTheme = CampaignCanvasTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    /// The shared floating window (T9), kept for the whole showing: opening and closing the story
    /// swaps what is drawn, never the window.
    @StateObject private var window = FloatingWindow()
    /// 0 is "still the window", 1 is "full screen". One value for both directions, because the two
    /// are the same journey — a collapse interrupted by a re-open resumes from where it had got to
    /// rather than snapping back to the window first.
    @State private var storyPhase: CGFloat = 0
    /// Outlives `orchestrator.storyOpen`: the orchestrator flips that the instant the user closes,
    /// but the viewer has to stay mounted until the collapse has finished running.
    @State private var viewerMounted = false
    /// The page overlay and full-screen chrome appear only after the media aperture has landed.
    @State private var storyOverlaysVisible = false
    @State private var storyOverlayRevealToken = 0

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
            let windowSize = storyWindowSize(config: config, screenSize: screenSize)
            let bounds = FloatingWindowBounds(
                screenSize: screenSize, safeInsets: safe, margin: config.window.margin,
                windowSize: windowSize)
            let resting = floatingRestingRect(
                windowSize: windowSize, bounds: bounds, position: config.window.position,
                dragFraction: orchestrator.dragFraction)
            let delta = window.delta
            // This reader's offset within the screen. Zero in the ordinary case — the view above
            // is full-bleed — but subtracted rather than assumed, so a host that nests `DigiaHost`
            // somewhere smaller still draws the window where the screen coordinates say it is
            // rather than that much further in again.
            let globalOrigin = geo.frame(in: .global).origin
            // Deliberately unclamped during an active drag — a fast flick can carry the
            // box past the safe area while the finger is still moving, the same
            // rubber-band feel the PiP has. `FloatingWindow.dragEnded` is what snaps it back.
            let left = resting.minX - globalOrigin.x
                + delta.width + window.flyOffsetFraction.width * resting.width
            let top = resting.minY - globalOrigin.y
                + delta.height + window.flyOffsetFraction.height * resting.height
            let activeTransition = orchestrator.storyOpen
                ? config.behavior.expandTransition
                : config.behavior.collapseTransition
            let windowAlpha = floaterStoryWindowAlpha(
                type: activeTransition.type,
                phase: storyPhase
            )
            let heroAlpha = floaterStoryHeroAlpha(
                type: activeTransition.type,
                phase: storyPhase
            )
            // `nil` while the story viewer is mounted, for the same reason the window itself is
            // not the active touch target then: a host's `hitTest` trusts this rect to claim
            // touches, and a rect published for a window behind a full-screen hero would claim
            // only a small part of an actually modal surface. While the story aperture is up,
            // `Digia.hasActiveOverlay` claims the screen.
            let publishedActiveRect: CGRect? =
                viewerMounted || orchestrator.storyOpen
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

            // The story draws inline inside the same full-bleed host layer as the window. The
            // `@State` above stays put, so the window returns exactly where the user left it.
            ZStack {
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
                        onDragChanged: { translation in
                            window.dragChanged(
                                translation, draggable: config.controls.draggable,
                                closing: orchestrator.closing || orchestrator.storyOpen)
                        },
                        onDragEnded: { translation, velocity in
                            window.dragEnded(
                                translation: translation, velocity: velocity, resting: resting,
                                bounds: bounds, draggable: config.controls.draggable,
                                closing: orchestrator.closing,
                                snapToCorner: config.controls.snapToCorner,
                                onCommit: { orchestrator.moveTo($0) })
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
                        .clipShape(ClampedRoundedRectangle(cornerRadius: config.window.cornerRadiusDp))
                        .floatingWindowShadow(config.window.shadow)
                        .overlay(
                            ClampedRoundedRectangle(cornerRadius: config.window.cornerRadiusDp)
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
                        .opacity(window.alpha * windowAlpha)
                }

                if viewerMounted {
                    let heroRect = floaterStoryHeroRect(
                        window: localWindowRect,
                        screen: screenSize,
                        phase: storyPhase
                    )
                    let heroRadius = floaterStoryHeroCornerRadius(
                        windowRadius: config.window.cornerRadiusDp,
                        phase: storyPhase
                    )
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .frame(width: screenSize.width, height: screenSize.height)
                        .zIndex(1)

                    ZStack(alignment: .topLeading) {
                        Color.black
                        storyViewer(
                            safeAreaInsets: safe,
                            showsOverlays: storyOverlaysVisible
                        )
                        .frame(width: screenSize.width, height: screenSize.height)
                        .transition(.identity)
                    }
                    .frame(width: heroRect.width, height: heroRect.height, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: heroRadius))
                    .position(x: heroRect.midX, y: heroRect.midY)
                    .opacity(heroAlpha)
                    .zIndex(2)
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
            window.runEntry(config.window.entryAnimation, fullscreen: false)
            // The impression is the first painted frame, not the routing decision.
            orchestrator.markVisible(token: state.token)
            // A start-expanded showing is already open, so `onChange(of: storyOpen)` below never
            // fires for it; grow the story out of the window from here instead.
            if orchestrator.storyOpen { runStoryTransition(opening: true) }
        }
        .onChange(of: orchestrator.closing) { closing in
            if closing { window.runExit(config.window.exitAnimation, fullscreen: false) }
        }
        .onDisappear {
            orchestrator.activeRect = nil
            orchestrator.setStoryOverlayActive(false)
        }
        .onChange(of: orchestrator.storyOpen) { open in runStoryTransition(opening: open) }
    }

    /// Runs the expand or the collapse, and keeps the viewer mounted for as long as it takes.
    ///
    /// The unmount is deferred by the collapse's own duration rather than driven by a completion
    /// handler: `withAnimation`'s completion is not available on every OS this SDK supports, and a
    /// timer that agrees with the animation it accompanies is simpler than one that has to be
    /// cancelled. A re-open inside that window is safe — `viewerMounted` is already true and the
    /// deferred close checks the orchestrator before acting.
    private func runStoryTransition(opening: Bool) {
        storyOverlayRevealToken += 1
        let revealToken = storyOverlayRevealToken
        if opening {
            let expand = config.behavior.expandTransition
            viewerMounted = true
            orchestrator.setStoryOverlayActive(true)
            storyOverlaysVisible = false
            if expand.isInstant {
                storyPhase = 1
                storyOverlaysVisible = true
                return
            }
            withAnimation(floatingEaseInOutQuart(duration: expand.duration)) { storyPhase = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + expand.duration) {
                if storyOverlayRevealToken == revealToken, orchestrator.storyOpen {
                    storyOverlaysVisible = true
                }
            }
            return
        }
        let collapse = config.behavior.collapseTransition
        storyOverlaysVisible = false
        if collapse.isInstant {
            storyPhase = 0
            viewerMounted = false
            orchestrator.setStoryOverlayActive(false)
            return
        }
        // Mirror image of the expand: the story stays mounted inside the aperture while the
        // aperture shrinks back to the window behind it, then unmounts.
        withAnimation(floatingEaseInOutQuart(duration: collapse.duration)) { storyPhase = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + collapse.duration) {
            // Only if the user has not re-opened it in the meantime.
            if !orchestrator.storyOpen {
                viewerMounted = false
                orchestrator.setStoryOverlayActive(false)
            }
        }
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
        .environment(\.digiaCampaignKey, state.payload.campaignKey)
    }

    /// The story itself.
    ///
    /// Every story host uses full-bleed bounds and supplies the device insets so media can cover
    /// the screen while authored chrome and page content remain inside the safe area.
    @ViewBuilder
    private func storyViewer(safeAreaInsets: EdgeInsets, showsOverlays: Bool) -> some View {
        if case .story(
            _, let pages, _, _, _, _, let restartOnCompleted, let startMuted, let chrome
        ) = config.story {
            // The floater keeps its own `FloaterEvent` vocabulary rather than the inline story's,
            // so it maps only the one interaction that has no equivalent there: reaching the end.
            // Everything else it already reports from the orchestrator.
            CanvasStoryViewer(
                pages: pages,
                chrome: chrome,
                initialIndex: orchestrator.storyInitialIndex,
                restartOnCompleted: restartOnCompleted,
                startMuted: startMuted,
                isDark: isDark,
                onAction: runCanvasAction,
                onDismiss: { orchestrator.closeStory() },
                showsOverlays: showsOverlays,
                safeAreaInsets: safeAreaInsets
            )
            .environment(\.digiaVariables, state.variableContext)
            .environment(\.digiaCampaignKey, state.payload.campaignKey)
            // Two vocabularies, and the split is by subject rather than by campaign type.
            //
            // `FloaterEvent` describes the *window's* life — it appeared, it was tapped, it was
            // dragged, the showing ended. `StoriesEvent` describes the *story's* — which page is
            // showing, which one the viewer left on, whether they reached the end. A story opened
            // from a floating window is the same story a rail opens, so it reports the same way,
            // and the two funnels stay comparable.
            //
            // The wire event names are unchanged by this: "Digia Step Viewed" already fired once
            // when the story opened, and now fires once per page — the first of which is that same
            // open. So this adds granularity rather than replacing a signal.
            .environment(\.canvasInteractions, CanvasInteractionReporter { interaction in
                let payload = state.payload
                switch interaction {
                case let .storyPageViewed(index, total):
                    SDKInstance.shared.reportStoryStepViewed(
                        payload, itemIndex: index + 1, itemTotal: total
                    )
                case let .storyPageDismissed(index, _):
                    SDKInstance.shared.reportStoryStepDismissed(payload, itemIndex: index + 1)
                case let .storyCompleted(total, ms):
                    SDKInstance.shared.reportStoryCompleted(
                        payload, itemTotal: total, timeToCompleteMs: ms.map(Int64.init)
                    )
                    // And the floater's own serving signal, which is what a
                    // `stopOn: experienceCompleted` frequency rule retires on.
                    SDKInstance.shared.floaterStoryOrchestrator.complete()
                // The window's tap already reports the open as an experience click, so a second
                // one here would double-count it.
                case .storyOpened, .carouselSlideViewed:
                    break
                }
            })
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
            FloaterVectorIcon(glyph: .close)
                .fill(Color.white)
                .frame(
                    width: config.controls.iconSize,
                    height: config.controls.iconSize
                )
                .padding(config.controls.iconSize * 0.3)
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
    /// `Action.showStory` can open this floater's story at an authored page; window taps
    /// without an authored action still open the story through `openStory()` above.
    private func runCanvasAction(_ request: CampaignCanvasActionRequest) {
        let action = request.actions.first?.resolved(with: state.variableContext)
        // Which level of the funnel this tap belongs to, decided by where it came from.
        //
        // A story page is a *step*, so a CTA on one reports the way it does in an inline story,
        // with the page it came from. The window is not a step — it is the campaign's only visible
        // surface, the thing the whole showing consists of — so a button the author drew on it is
        // a click on the experience itself, exactly like a tap on the window's empty canvas
        // already was.
        //
        // Exactly one event either way. Emitting both, which is what happened when the action
        // runner reported a step click of its own, put two identically-named "Digia Step Clicked"
        // events on the wire for a single tap on a story page.
        if let step = request.step, step.kind == .storyPage {
            SDKInstance.shared.reportStoryStepClicked(
                state.payload,
                itemIndex: step.index + 1,
                ctaLabel: request.label,
                actionType: action?.analyticsType,
                actionUrl: action?.analyticsURL
            )
        } else {
            SDKInstance.shared.reportFloaterStoryClicked(
                elementId: request.elementId,
                actionType: action?.analyticsType ?? "",
                ctaRole: request.isPrimary ? "primary" : "secondary",
                ctaLabel: request.label,
                actionUrl: action?.analyticsURL
            )
        }
        SDKInstance.shared.runFloaterStoryAction(state: state, request: request)
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

/// The window's size for the given screen.
///
/// Width is a fraction of the screen (capped on a large screen, see
/// `floaterStoryWindowWidth`) and height follows the authored aspect ratio — which
/// the dashboard derives from the window canvas's own shape, so the box is always the box
/// the author drew. Where it rests is the shared window's `floatingRestingRect`.
private func storyWindowSize(config: FloaterStoryConfig, screenSize: CGSize) -> CGSize {
    let width = floaterStoryWindowWidth(
        screenWidth: screenSize.width,
        widthFraction: config.window.widthFraction,
        canvasWidth: config.canvas.width,
        largeScreen: isLargeScreen(shortestSide: min(screenSize.width, screenSize.height))
    )
    return CGSize(width: width, height: width / config.window.aspectRatio)
}
