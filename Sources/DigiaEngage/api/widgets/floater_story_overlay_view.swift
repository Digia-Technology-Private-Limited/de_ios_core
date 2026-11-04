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
// everything only a media window has: no `AVPlayer`, no playback chrome, and no continuous
// media surface. The story still uses the same hero shape: mount the viewer first, clip it
// through the floating window's aperture, then grow that aperture to the screen.

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
            let resting = floatingRestingRect(
                size: .configured(
                    widthFraction: config.window.widthFraction,
                    aspectRatio: config.window.aspectRatio
                ),
                screenSize: screenSize,
                safeInsets: FloatingWindowInsets(safe),
                margin: config.window.margin,
                position: config.window.position,
                dragFraction: orchestrator.dragFraction
            )
            let delta = window.restingDelta
            // This reader's offset within the screen. Zero in the ordinary case — the view above
            // is full-bleed — but subtracted rather than assumed, so a host that nests `DigiaHost`
            // somewhere smaller still draws the window where the screen coordinates say it is
            // rather than that much further in again.
            let globalOrigin = geo.frame(in: .global).origin
            // Deliberately unclamped during an active drag — a fast flick can carry the
            // box past the safe area while the finger is still moving, the same
            // rubber-band feel the PiP has. `window.dragEnded` is what snaps it back.
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
                        .clipShape(ClampedRoundedRectangle(cornerRadius: config.window.cornerRadiusDp))
                        .floatingWindowShadow(applied: config.window.shadow)
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
            runEntryAnimation()
            // The impression is the first painted frame, not the routing decision.
            orchestrator.markVisible(token: state.token)
            // A start-expanded showing is already open, so `onChange(of: storyOpen)` below never
            // fires for it; grow the story out of the window from here instead.
            if orchestrator.storyOpen { runStoryTransition(opening: true) }
        }
        .onChange(of: orchestrator.closing) { closing in
            if closing { runExitAnimation() }
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
            withAnimation(storyEaseInOutQuart(duration: expand.duration)) { storyPhase = 1 }
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
        withAnimation(storyEaseInOutQuart(duration: collapse.duration)) { storyPhase = 0 }
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
        .environment(\.canvasVideoUsesStoryPlayback, true)
    }

    /// The story itself, presented through F's `StoryViewer` building blocks (T15).
    ///
    /// The window parts (drag shield, hero aperture, entry/exit) stay on lane D's
    /// `FloatingWindow` API, untouched above; this is only the content: a `StoryViewerSession`
    /// (one mute state per showing, reset to the campaign default on every open) driving the
    /// story's pages through `story/pages/*` — `CanvasStoryPage`, the borrowed pool player or
    /// the still below with the authored overlay above — and the authored chrome over all of
    /// it. Mute, session and plan-driver behavior comes from the viewer; the floater only
    /// supplies the inputs (stories, start index, reporter — no rail, so no handoff key) and
    /// maps analytics into its own vocabulary, exactly as before.
    ///
    /// Q1 stays as-is: with no thumbnail image the mapped item carries no poster, so the page
    /// keeps its still/backdrop until the first frame.
    @ViewBuilder
    private func storyViewer(safeAreaInsets: EdgeInsets, showsOverlays: Bool) -> some View {
        if case .story(
            _, let pages, _, _, _, _, _, let restartOnCompleted, let startMuted, let chrome
        ) = config.story {
            FloaterStoryContentViewer(
                pages: pages,
                chrome: chrome,
                payload: state.payload,
                initialIndex: orchestrator.storyInitialIndex,
                restartOnCompleted: restartOnCompleted,
                startMuted: startMuted,
                isDark: isDark,
                namespace: state.payload.campaignKey,
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
                // `.storyPageDismissed`/`.storyCompleted` are retained defensively — the session reporter owns dismiss/completion.
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

    private func handleDragChanged(_ translation: CGSize) {
        guard config.controls.draggable, !orchestrator.closing, !orchestrator.storyOpen
        else { return }
        window.dragChanged(translation)
    }

    private func handleDragEnded(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        resting: CGRect,
        screenSize: CGSize,
        safe: EdgeInsets
    ) {
        guard !orchestrator.closing else { return }
        window.dragEnded(
            translation: translation,
            predictedEndTranslation: predictedEndTranslation,
            resting: resting,
            screenSize: screenSize,
            safeInsets: FloatingWindowInsets(safe),
            margin: config.window.margin,
            draggable: config.controls.draggable,
            snapToCorner: config.controls.snapToCorner,
            onCommit: { orchestrator.moveTo($0) }
        )
    }

    // MARK: - Entry/exit

    private func runEntryAnimation() {
        window.runEntryAnimation(entry: config.window.entryAnimation, alreadyVisible: false)
    }

    private func runExitAnimation() {
        window.runExitAnimation(exit: config.window.exitAnimation, skipWhenCovered: false)
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

/// The floater story's viewer session, reported the way the canvas rail reports its own story:
/// completion once with its time, dismissal on close before the end. The payload's own mapping
/// (step viewed per page, completion retiring the showing) lives in the `canvasInteractions`
/// closure the content viewer installs; this reporter carries the same two wire calls for the
/// session-driven paths (`advance`/`dismiss`), so the funnel is identical either way.
@MainActor
private struct FloaterStoryViewerReporter: StoryViewerReporter {
    let payload: CEPTriggerPayload

    func onCompleted(total: Int, timeToCompleteMs: Int64) {
        SDKInstance.shared.reportStoryCompleted(
            payload, itemTotal: total, timeToCompleteMs: timeToCompleteMs
        )
        // And the floater's own serving signal, which is what a
        // `stopOn: experienceCompleted` frequency rule retires on.
        SDKInstance.shared.floaterStoryOrchestrator.complete()
    }

    func onDismissed(index: Int) {
        SDKInstance.shared.reportStoryStepDismissed(payload, itemIndex: index + 1)
    }
}

/// The floater story's content on the shared story viewer (T15): one `StoryViewerSession`
/// (mute + progress + completion guard keyed on the open, reset to the campaign default every
/// time the story opens) driving the pages through `story/pages/*`, with the authored page
/// overlay and chrome drawn over them exactly as before.
///
/// Mirrors Android's `CanvasStoryViewer`-on-`StoryViewer`: the canvas story maps each page to a
/// `StoryItemConfig` (`canvasStoryItem`, the same mapping the rails read) and lets the viewer
/// own timing, mute, borrowing and the download plan. Intended iOS differences: the viewer is
/// a SwiftUI view over `StoryViewerSession` (Android's is a composable over its session); the
/// mute toggle reaches the live player at once through `MediaVideoState.setMuted` (the pre-T15
/// viewer dropped it — the hosted mute test now asserts the live mute); a pool re-borrow after
/// a restart may hand back the same player object (the restart test asserts replay, not
/// identity).
@MainActor
private struct FloaterStoryContentViewer: View {
    let pages: [CampaignCanvasStoryPage]
    let chrome: CampaignCanvas
    let payload: CEPTriggerPayload
    let initialIndex: Int
    let restartOnCompleted: Bool
    let startMuted: Bool
    let isDark: Bool
    let namespace: String?
    let onAction: (CampaignCanvasActionRequest) -> Void
    let onDismiss: () -> Void
    var showsOverlays = true
    var safeAreaInsets = EdgeInsets()

    /// The canvas story's own default when a page sets no duration, resolved the same way the
    /// parser resolves it (`CampaignCanvasParser.parseStory`, `?? 5`).
    private static let defaultDurationMs = 5000

    @StateObject private var session: StoryViewerSession
    @Environment(\.canvasInteractions) private var reportInteraction

    @State private var elapsed = 0.0
    @State private var videoProgress = 0.0
    @State private var videoStalled = 0.0
    @State private var lastVideoProgress = 0.0
    @State private var videoReady = false
    @State private var videoBuffering = false
    /// A video page whose player gave up: its authored duration runs instead. Advancing at once
    /// would skip the page; stalling would hang the story — the pre-T15 viewer ran the authored
    /// timer here, so this keeps doing that.
    @State private var videoFailed = false
    @State private var paused = false
    @State private var applicationActive = UIApplication.shared.applicationState == .active
    @State private var lastReportedIndex: Int?
    /// The byte half of the download plan (players borrow through `MediaVideo`). The plan
    /// driver, like the mute state, belongs to the viewer session's lifetime.
    @State private var planDriver = StoryPlanDriver()
    @State private var firstFrameShown: Bool
    @State private var slowSource = PathSlowNetworkSource()

    private let stories: [StoryItemConfig]

    init(
        pages: [CampaignCanvasStoryPage],
        chrome: CampaignCanvas,
        payload: CEPTriggerPayload,
        initialIndex: Int,
        restartOnCompleted: Bool,
        startMuted: Bool,
        isDark: Bool,
        namespace: String?,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void,
        onDismiss: @escaping @MainActor @Sendable () -> Void,
        showsOverlays: Bool = true,
        safeAreaInsets: EdgeInsets = EdgeInsets()
    ) {
        self.pages = pages
        self.chrome = chrome
        self.payload = payload
        self.initialIndex = initialIndex
        self.restartOnCompleted = restartOnCompleted
        self.startMuted = startMuted
        self.isDark = isDark
        self.namespace = namespace
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.showsOverlays = showsOverlays
        self.safeAreaInsets = safeAreaInsets
        let items = pages.map(canvasStoryItem)
        self.stories = items
        let clamped = min(max(0, initialIndex), max(items.count - 1, 0))
        _session = StateObject(wrappedValue: StoryViewerSession(
            stories: items,
            startIndex: clamped,
            handoffKey: nil,
            restartOnCompleted: restartOnCompleted,
            startMuted: startMuted,
            reporter: FloaterStoryViewerReporter(payload: payload),
            onDismiss: onDismiss
        ))
        _firstFrameShown = State(initialValue:
            items.indices.contains(clamped) ? items[clamped].type != .video : true)
    }

    private var currentIndex: Int { session.currentIndex }

    private var currentItem: StoryItemConfig? {
        stories.indices.contains(currentIndex) ? stories[currentIndex] : nil
    }

    private var currentPage: CampaignCanvasStoryPage? {
        pages.indices.contains(currentIndex) ? pages[currentIndex] : nil
    }

    private var currentDuration: Double {
        storyPageDurationSeconds(item: currentItem, defaultMs: Self.defaultDurationMs) ?? 0
    }

    private var progress: Double {
        if currentItem?.type == .video, !videoFailed {
            return min(max(videoProgress, 0), 1)
        }
        return min(max(elapsed / max(currentDuration, 0.1), 0), 1)
    }

    private var planInput: String {
        "\(currentIndex)-\(firstFrameShown)-\(session.replayTick)"
    }

    var body: some View {
        GeometryReader { proxy in
            // The width the chrome and page are scaled against: the full-bleed
            // reader minus the device's unsafe margins.
            let contentWidth = max(
                0, proxy.size.width - safeAreaInsets.leading - safeAreaInsets.trailing
            )
            // Each layer is pinned to the safe region, so neither can size the
            // stack. On a tablet the width-scaled portrait page is taller than
            // the reader; it bottom-anchors and loses its top, as the media
            // does, and the chrome stays at the top edge. Phones draw as before.
            let safeHeight = max(
                0, proxy.size.height - safeAreaInsets.top - safeAreaInsets.bottom
            )
            // The page an action came from travels with it, so a CTA inside story 3 reports as a
            // step click on story 3 rather than as an anonymous click on the card.
            let pageAction: (CampaignCanvasActionRequest) -> Void = { request in
                var stamped = request
                stamped.step = CanvasStep(
                    kind: .storyPage, index: session.currentIndex, total: pages.count
                )
                onAction(stamped)
            }
            ZStack(alignment: .top) {
                // Navigation sits under the chrome and over the page, so a
                // button the author placed on a page still wins the tap.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { previous() }
                    Color.clear.contentShape(Rectangle()).onTapGesture { next() }
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.2)
                        .onChanged { _ in pause() }
                        .onEnded { _ in resume() }
                )
                .allowsHitTesting(showsOverlays)
                .accessibilityHidden(!showsOverlays)

                if let page = currentPage {
                    // Both the overlay and the chrome are authored against the safe
                    // region, so both draw at the same scale and inside it.
                    let scale = page.canvas.width > 0 ? contentWidth / page.canvas.width : 1
                    pageOverlay(
                        page: page, scale: scale, contentWidth: contentWidth,
                        safeHeight: safeHeight, pageAction: pageAction
                    )

                    ScaledCanvasStage(
                        canvas: chrome,
                        width: contentWidth,
                        height: chrome.height * scale,
                        cornerRadius: 0,
                        isDark: isDark,
                        onAction: pageAction,
                        // Transparent by design — the page shows through, as on Flutter.
                        showBackground: false
                    )
                    .frame(height: safeHeight, alignment: .top)
                    .clipped()
                    .environment(
                        \.canvasStoryViewer,
                        CanvasStoryViewerState(
                            index: session.currentIndex,
                            pageCount: pages.count,
                            progress: progress,
                            muted: session.muted
                        )
                    )
                    .environment(\.canvasStoryClose, CanvasStoryCallback(run: dismissWithReport))
                    .environment(
                        \.canvasStoryToggleMute,
                        CanvasStoryCallback(run: { session.muted.toggle() })
                    )
                    .opacity(showsOverlays ? 1 : 0)
                    .allowsHitTesting(showsOverlays)
                    .accessibilityHidden(!showsOverlays)
                }
            }
            // Inside the safe region, and the backdrop below outside it. The
            // padding is *inside* the frame that follows, so the stack is offered
            // the reader minus these insets while the frame — and so the media
            // behind it — still covers the whole reader.
            .padding(safeAreaInsets)
            // The screen, and only the screen. Without this the stack takes its
            // size from its largest child, and a story's media is routinely
            // larger than the screen — a filling image reports an ideal size in
            // the image's own pixels. That grew the stack, which carried the
            // top-aligned chrome above the top edge and the bottom-anchored page
            // canvas below the bottom one.
            .frame(width: proxy.size.width, height: proxy.size.height)
            // The media goes here rather than in the stack for the same reason:
            // a background is measured against its parent and can never resize
            // it, however large the image inside turns out to be. It still
            // bleeds under the status bar and the home indicator, because a
            // story's media is the screen.
            .background {
                floaterStoryMedia()
                    .ignoresSafeArea()
            }
        }
        // Full-bleed: the reader reports the device's screen, not the safe-area-carved box,
        // so the safe-region math above matches the pre-T15 viewer exactly.
        .ignoresSafeArea()
        .onAppear {
            reportPageViewed(session.currentIndex)
        }
        .onChange(of: session.currentIndex) { _ in
            resetTiming()
            let isVideo = currentItem?.type == .video
            firstFrameShown = !(isVideo ?? false)
            drivePlan()
            reportPageViewed(session.currentIndex)
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            tick()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification
        )) { _ in
            applicationActive = false
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            applicationActive = true
        }
        .onDisappear {
            planDriver.cancelAll()
        }
        .task(id: planInput) {
            drivePlan()
        }
    }

    /// The story's media, through the shared viewer pages: the borrowed pool player (video)
    /// or still (image) below, never an empty box. A page with no media URL draws nothing —
    /// the pre-T15 viewer skipped those too (no spinner, no fetch), so the golden of an
    /// expanded story with imageless pages is unchanged. The authored overlay lives in the
    /// main stack above (not here), exactly as before.
    @ViewBuilder
    private func floaterStoryMedia() -> some View {
        ZStack {
            Color.black
            if let item = currentItem, !item.url.isEmpty {
                let pageIndex = currentIndex
                if item.type == .video {
                    VideoStoryPage(
                        item: item,
                        pageKey: session.pageKey(index: pageIndex, namespace: namespace),
                        muted: session.muted,
                        playing: !paused && applicationActive,
                        onReady: { _ in
                            guard session.currentIndex == pageIndex else { return }
                            videoReady = true
                            firstFrameShown = true
                            drivePlan()
                        },
                        onProgress: {
                            guard session.currentIndex == pageIndex else { return }
                            videoProgress = $0
                        },
                        onEnded: {
                            guard session.currentIndex == pageIndex else { return }
                            next()
                        },
                        onBuffering: {
                            guard session.currentIndex == pageIndex else { return }
                            videoBuffering = $0
                        },
                        onFailed: {
                            // A broken full-screen item runs its authored duration, as before.
                            guard session.currentIndex == pageIndex else { return }
                            videoFailed = true
                        }
                    )
                    .id("\(pageIndex)-\(session.replayTick)")
                } else {
                    ImageStoryPage(item: item) {
                        guard session.currentIndex == pageIndex else { return }
                        videoReady = true
                        firstFrameShown = true
                        drivePlan()
                    }
                    .id("\(pageIndex)-\(session.replayTick)")
                }
            }
        }
    }

    /// The authored page drawn over the media, at the safe-region scale.
    @ViewBuilder
    private func pageOverlay(
        page: CampaignCanvasStoryPage, scale: CGFloat, contentWidth: CGFloat,
        safeHeight: CGFloat, pageAction: @escaping (CampaignCanvasActionRequest) -> Void
    ) -> some View {
        ScaledCanvasStage(
            canvas: page.canvas,
            width: contentWidth,
            height: page.canvas.height * scale,
            cornerRadius: 0,
            isDark: isDark,
            onAction: pageAction
        )
        .frame(height: safeHeight, alignment: .bottom)
        .clipped()
        .opacity(showsOverlays ? 1 : 0)
        .allowsHitTesting(showsOverlays)
        .accessibilityHidden(!showsOverlays)
    }

    private func drivePlan() {
        let index = currentIndex
        planDriver.update(
            actions: StoryDownloadPlan.plan(
                stories: stories.map { StoryDownloadPlan.Item(isVideo: $0.type == .video) },
                currentIndex: index,
                firstFrameShown: firstFrameShown,
                slowNetwork: slowSource.isSlow
            ),
            urlOf: { stories[$0].url },
            isVideoOf: { stories[$0].type == .video }
        )
    }

    private func reportPageViewed(_ pageIndex: Int) {
        guard lastReportedIndex != pageIndex else { return }
        lastReportedIndex = pageIndex
        reportInteraction(.storyPageViewed(index: pageIndex, total: pages.count))
    }

    /// Closing before the end is a dismissal; closing *at* the end is the completion already
    /// reported by `next`. Distinguishing them is what makes drop-off measurable — a viewer that
    /// always reported a dismissal would show 100% abandonment.
    private func dismissWithReport() {
        session.dismiss()
    }

    private func tick() {
        guard applicationActive, !paused, let item = currentItem else { return }
        if item.type == .video, !videoFailed {
            // File download and buffering are legitimate loading. Start the
            // watchdog only after the player has displayed its first frame.
            if !videoReady || videoBuffering { return }
            if videoProgress > lastVideoProgress + 0.0001 {
                lastVideoProgress = videoProgress
                videoStalled = 0
            } else {
                videoStalled += 0.05
                if videoStalled >= 10 { next() }
            }
            return
        }
        // A zero-duration image degrades forward instead of stalling: the frame is skipped
        // at once, never waited on.
        guard let duration = storyPageDurationSeconds(
            item: item, defaultMs: Self.defaultDurationMs) else {
            next()
            return
        }
        elapsed += 0.05
        if elapsed >= duration {
            next()
        }
    }

    private func resetTiming() {
        elapsed = 0
        videoProgress = 0
        lastVideoProgress = 0
        videoStalled = 0
        videoBuffering = false
        videoReady = false
        videoFailed = false
    }

    private func next() {
        resetTiming()
        // Completion (once-only) + restart/dismiss live in `session.advance()` — never bypass it.
        session.advance()
    }

    private func previous() {
        resetTiming()
        if currentIndex == 0 {
            // Re-show the first story from the top (replayTick remounts its page).
            session.goBack()
        } else {
            session.showPage(index: currentIndex - 1)
        }
    }

    private func pause() {
        guard !paused else { return }
        paused = true
    }

    private func resume() {
        guard paused else { return }
        paused = false
    }
}
