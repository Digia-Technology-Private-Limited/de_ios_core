import AVFoundation
import Combine
import Foundation
import SwiftUI
import UIKit

// Direct port of `pip_renderer.dart` (`_PipSession`) / `FloaterSession.kt`. **One
// container view, growing — never two subtrees swapping.** The collapsed window and
// the full-screen state are the same positioned+sized container, with
// `FloaterMediaView` inside it the whole time; that is what keeps playback
// continuous: its `MediaVideo` joins the player `FloaterOrchestrator` leased, and
// is never remounted mid-transition. See `ai_docs/pip-campaign-design.md` §4.4.
// The window around it (drag, fling, snap, entry/exit, shadow) is the shared
// `FloatingWindow` the story floater floats in too (T9).
//
// Mounted as a plain SwiftUI sibling directly in `DigiaHost`'s own `ZStack`, not
// wrapped in a `UIViewControllerRepresentable`/nested `UIHostingController` (an
// earlier approach) — that nesting put a second `_UIHostingView` inside the outer
// one, and touches through it were resolved inconsistently by Apple's private
// representable-hosting hit-test dispatch: the same tap coordinates, moments apart,
// sometimes correctly reached this content and sometimes silently didn't, with no
// code-level trigger for which happened. `FloaterSessionView`'s drag/tap
// shield (the shared `FloaterCollapsedInteractionView`) and its chrome buttons
// scope themselves to the collapsed rect (or the full screen when expanded) using
// plain SwiftUI layout and an ordinary `UIViewRepresentable` with no nested hosting
// controller inside it, so there's no need for a UIKit-level "claims this point"
// gate at the mount point itself — a `ZStack` sibling that renders nothing when
// `orchestrator.state` is nil is naturally untouchable the rest of the time.

@MainActor
struct FloaterOverlayView: View {
    @ObservedObject private var orchestrator = SDKInstance.shared.floaterOrchestrator

    var body: some View {
        if let state = orchestrator.state, !orchestrator.awaitingMedia {
            FloaterSessionView(state: state, orchestrator: orchestrator)
                .id(state.token)
                // Full-bleed in both states, and placed inside the real window insets below, as
                // the story floater is. Respecting the container's safe area as well inset the
                // collapsed window twice: once by the container, again by the insets it reported.
                .ignoresSafeArea()
        }
    }
}

/// The device's real safe-area insets, read from the key `UIWindow` rather than from SwiftUI.
///
/// A `GeometryReader`'s own `safeAreaInsets` cannot be trusted for a floating window, because what
/// it reports depends on how the *host app* embedded `DigiaHost` — inset inside a safe area, or
/// full-bleed, or somewhere in between — and a full-bleed reader reports zero regardless. A window
/// positioned from that lands under the notch in one app and inset twice over in another.
///
/// The window is the only thing on screen that has to be placed against the physical device rather
/// than against its container, so it asks the device. Shared with the story floater, which had the
/// same symptom for the same reason.
@MainActor var activeFloaterWindowSafeAreaInsets: EdgeInsets {
    activeFloaterWindowGeometry.safeArea
}

/// Test seam for `activeFloaterWindowGeometry`. The package's test bundle runs without a host app,
/// so there is no window scene to read the device from; snapshot tests pin the device here. Never
/// set in production, where `nil` leaves the lookup below unchanged.
@MainActor var activeFloaterWindowGeometryOverride: (bounds: CGRect, safeArea: EdgeInsets)?

/// The device's screen box and its safe-area insets, taken from the same `UIWindow`.
///
/// Both together, deliberately. Reading the size from SwiftUI and the insets from UIKit is how the
/// story floater ended up inset twice: a `GeometryReader` at the root of a hosting controller
/// reports a size that has *already* had the safe area carved out of it, so subtracting real insets
/// from that height again pushes a window far further in from the top and bottom than the author
/// asked for — barely noticeable on a large window, glaring on a small one, where the gaps are most
/// of what you see.
///
/// Taking both from the window makes the pair consistent by construction, whatever the host app did
/// with `DigiaHost`.
@MainActor var activeFloaterWindowGeometry: (bounds: CGRect, safeArea: EdgeInsets) {
    if let override = activeFloaterWindowGeometryOverride { return override }
    let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
        .flatMap(\.windows)
        .first(where: { $0.safeAreaInsets.top > 0 || $0.safeAreaInsets.bottom > 0 })
        ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    guard let window else { return (.zero, EdgeInsets()) }
    let insets = window.safeAreaInsets
    return (
        window.bounds,
        EdgeInsets(
            top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    )
}

/// The collapsed chrome buttons' rects, in the SAME local coordinate space `activeRect`/
/// `FloaterCollapsedInteractionView`'s gesture handling already uses — so a tap that lands on a
/// button can be told apart from a tap on the plain media surface. Without this, the shield's
/// own `UITapGestureRecognizer` (attached to a view spanning the whole collapsed rect) and a
/// chrome button's SwiftUI `Button` sit in the same view tree with no established precedence
/// between them; Android's Compose port hit the analogous bug concretely (mute also expanded,
/// confirmed on-device) via a different mechanism (`Initial`-pass dispatch seeing the whole
/// subtree ancestor-first) — this guard closes off the same class of risk here regardless of
/// which exact interop rule would otherwise decide it.
///
/// Computed analytically from `config.controls.iconSize`/`.margin` — the SAME values
/// `FloaterChromeView`'s `.overlay(alignment:)` positions the actual pills with — matching
/// `FloaterChromePill`'s own ratios (`size * 0.3` padding each side, `size * 0.55` spacing
/// between icons) exactly, so this stays correct as long as that pill's own geometry doesn't
/// change independently of this function.
private func chromeButtonRects(activeRect: CGRect, config: FloaterConfig) -> [CGRect] {
    let iconSize = config.controls.iconSize
    let margin = config.controls.margin
    let pillHeight = iconSize * 1.6
    func pillWidth(iconCount: Int) -> CGFloat {
        guard iconCount > 0 else { return 0 }
        let n = CGFloat(iconCount)
        return iconSize * n + iconSize * 0.55 * (n - 1) + iconSize * 0.6
    }

    var rects: [CGRect] = []
    if config.controls.showClose {
        let width = pillWidth(iconCount: 1)
        rects.append(
            CGRect(
                x: activeRect.maxX - margin.right - width, y: activeRect.minY + margin.top,
                width: width, height: pillHeight
            ))
    }
    let showsProgress = config.controls.showProgress && config.media.kind.isPlayable
    let bottomInset: CGFloat = showsProgress ? 8 : margin.bottom
    if config.controls.showExpand, config.behavior.tapExpands {
        let width = pillWidth(iconCount: 1)
        rects.append(
            CGRect(
                x: activeRect.minX + margin.left, y: activeRect.maxY - bottomInset - pillHeight,
                width: width, height: pillHeight
            ))
    }
    let showsMute = config.controls.showMute && config.media.kind == .video
    let showsPlayPause = config.controls.showPlayPause && config.media.kind.isPlayable
    if showsMute || showsPlayPause {
        let count = (showsMute ? 1 : 0) + (showsPlayPause ? 1 : 0)
        let width = pillWidth(iconCount: count)
        rects.append(
            CGRect(
                x: activeRect.maxX - margin.right - width,
                y: activeRect.maxY - bottomInset - pillHeight,
                width: width, height: pillHeight
            ))
    }
    return rects
}

private struct FloaterSessionView: View {
    let state: ActiveFloaterState
    @ObservedObject var orchestrator: FloaterOrchestrator
    // For resolving `config.collapsed.borderColor`/`config.expanded.backgroundColor`
    // (design-token-aware `CampaignColor?`, not a flat SwiftUI `Color?`) to an actual
    // color at render time — a token's real hex depends on the active theme, which
    // isn't known while parsing. Same pattern `CampaignCanvasView` already uses.
    @ObservedObject private var canvasTheme = CampaignCanvasTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    /// The shared floating window: drag, fling, snap and entry/exit (T9). One per showing,
    /// kept across expand and collapse, so a content swap never rebuilds it.
    @StateObject private var window = FloatingWindow()
    @State private var expandedContentVisible = false

    private var config: FloaterConfig { state.config }
    private var expanded: Bool { orchestrator.surface == .expanded }
    private var isDark: Bool { canvasTheme.isDark(colorScheme) }

    var body: some View {
        GeometryReader { geo in
            let screenSize = geo.size
            // The overlay is full-bleed, which makes this GeometryReader report zero
            // safe-area insets. Keep media edge-to-edge, but source the real window insets
            // for the collapsed window, chrome and canvas overlays.
            let safe = activeFloaterWindowSafeAreaInsets
            let windowSize = collapsedWindowSize(config: config, screenSize: screenSize)
            let bounds = FloatingWindowBounds(
                screenSize: screenSize, safeInsets: safe, margin: config.collapsed.margin,
                windowSize: windowSize)
            let resting = floatingRestingRect(
                windowSize: windowSize, bounds: bounds, position: config.collapsed.position,
                dragFraction: orchestrator.dragFraction)
            let delta = window.delta
            let width = expanded ? screenSize.width : resting.width
            let height = expanded ? screenSize.height : resting.height
            // Deliberately unclamped during an active drag — a fast flick can carry
            // the box past the safe area (or screen edge) while the finger is still
            // moving, the same rubber-band feel Android's PIP already has, rather
            // than hitting a hard wall mid-gesture. `FloatingWindow.dragEnded`, at drag
            // end, is what snaps it back to a safe-area-respecting corner (via its
            // settle spring) — that clamp is real; it's just not also duplicated here
            // for every frame of the gesture itself.
            let left =
                (expanded ? 0 : resting.minX + delta.width)
                + window.flyOffsetFraction.width * width
            let top =
                (expanded ? 0 : resting.minY + delta.height)
                + window.flyOffsetFraction.height * height
            let cornerRadius = expanded ? 0 : config.collapsed.cornerRadiusDp

            // The rect to publish to `orchestrator.activeRect` (see the `.background`
            // below), computed directly from the same `left`/`top`/`width`/`height`
            // this body already uses to draw and position the box — NOT read back via
            // a nested `GeometryReader` placed after `.position(...)` in the modifier
            // chain below. `.position(x:y:)` makes a view report a flexible,
            // fills-all-available-space size to anything chained *after* it (that's
            // how it can be placed anywhere within its parent), so a `GeometryReader`
            // reading `.frame(in: .global)` from a `.background` after `.position()`
            // measured that inflated available-space frame (≈ full screen) instead of
            // the box's actual small size — confirmed live: the box itself drew and
            // dragged correctly at its real small size the whole time, but the
            // published rect was near-fullscreen, so `DigiaModule.swift`'s hitTest
            // (which trusts this rect) was claiming almost every touch on screen
            // while the PIP was collapsed. `geo` is the outermost reader here, so its
            // `.global` frame is unaffected by that quirk.
            let globalOrigin = geo.frame(in: .global).origin
            let publishedActiveRect = CGRect(
                x: left + globalOrigin.x, y: top + globalOrigin.y, width: width, height: height
            )

            ZStack {
                // Drag-to-reposition and tap-to-expand, via UIKit gesture recognizers
                // rather than a plain SwiftUI `DragGesture` (a version tried and
                // reverted) — a `DragGesture` updating `@State` on every touch-move
                // forces `FloaterSessionView.body` (this whole `GeometryReader`,
                // media, and chrome subtree) to re-evaluate on every single move
                // event, and that proved too expensive to keep pace with the
                // finger — confirmed live as visible flicker/lag, the box trailing
                // behind rather than tracking it. `UIPanGestureRecognizer` delivers
                // through UIKit's own responder chain, not SwiftUI's diffing, and is
                // what this codebase used before discovering the *separate* bug
                // (nested `UIHostingController` hit-test non-determinism, described
                // in this file's own top-of-file comment) that motivated moving away
                // from it. That nesting is gone now — this shield lives as a plain
                // `UIViewRepresentable` directly in the same flat SwiftUI tree as
                // everything else, so it doesn't reintroduce what actually broke.
                if !expanded, config.controls.draggable || config.behavior.tapExpands {
                    let activeRect = CGRect(x: left, y: top, width: width, height: height)
                    FloaterCollapsedInteractionView(
                        activeRect: activeRect,
                        draggable: config.controls.draggable,
                        tapExpands: config.behavior.tapExpands,
                        closing: orchestrator.closing,
                        onDragChanged: { translation in
                            window.dragChanged(
                                translation, draggable: config.controls.draggable,
                                closing: expanded || orchestrator.closing)
                        },
                        onDragEnded: { translation, velocity in
                            window.dragEnded(
                                translation: translation, velocity: velocity, resting: resting,
                                bounds: bounds, draggable: config.controls.draggable,
                                closing: expanded || orchestrator.closing,
                                snapToCorner: config.controls.snapToCorner,
                                onCommit: { orchestrator.moveTo($0) })
                        },
                        onTap: {
                            expandFromCollapsedMediaTap()
                        },
                        chromeButtonBounds: chromeButtonRects(
                            activeRect: activeRect, config: config)
                    )
                    .frame(width: screenSize.width, height: screenSize.height)
                }

                ZStack {
                    // The window's content. Mounted once for the showing and never inside a
                    // branch on `expanded`, so growing to full screen (a content swap) keeps the
                    // same video layer and player instead of rebuilding them.
                    FloaterMediaView(
                        media: config.media,
                        videoPlayerKey: floaterVideoPlayerKey(state),
                        videoShowAgain: orchestrator.videoShowAgain,
                        muted: orchestrator.muted,
                        cover: !expanded || config.expanded.cover,
                        resolvedUrl: state.resolvedMediaUrl,
                        preloadedImage: orchestrator.preloadedImage
                    )
                    .environment(\.digiaCampaignKey, state.campaign.campaignKey)
                    .allowsHitTesting(false)
                    .zIndex(0)
                    if expanded, config.expanded.scrimOpacity > 0 {
                        FloaterScrimView(opacity: config.expanded.scrimOpacity)
                            .zIndex(1)
                    }
                    if expanded, expandedContentVisible {
                        FloaterExpandedContentView(state: state, safeAreaInsets: safe)
                            .zIndex(2)
                    }
                }
                .frame(width: width, height: height)
                .clipShape(ClampedRoundedRectangle(cornerRadius: cornerRadius))
                .floatingWindowShadow(!expanded && config.collapsed.shadow)
                // Same "cheap no-op instead of a different view" shape as the shadow above,
                // and for the same reason: switching between `AnyView(RoundedRectangle...)`
                // and `AnyView(EmptyView())` on `expanded` is a discrete view-identity swap,
                // not an animatable property change, so `.animation(value:)` below has
                // nothing to interpolate for it — the border popped in at its final geometry
                // the instant `expanded` flipped, while the box's own size/position (plain
                // animatable values) were still mid-transition, reading as "an empty
                // bordered box appears at the destination, then the content catches up to
                // it." Keeping the SAME `RoundedRectangle` shape always mounted and animating
                // `lineWidth` to `0` instead lets it interpolate alongside everything else.
                .overlay(
                    ClampedRoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            config.collapsed.borderColor.map {
                                canvasTheme.color($0, isDark: isDark)
                            } ?? .white,
                            lineWidth: (!expanded && config.collapsed.borderWidthDp > 0)
                                ? config.collapsed.borderWidthDp : 0
                        )
                )
                .background(
                    (config.expanded.backgroundColor.map { canvasTheme.color($0, isDark: isDark) }
                        ?? .black)
                        .opacity(expanded ? 1 : 0)
                )
                // Image/GIF/Lottie surfaces can be backed by library-owned render layers.
                // Apply chrome as the final window overlay, with an explicit z-order, so the
                // controls stay visually above every media kind in the collapsed state.
                .overlay {
                    FloaterChromeView(
                        state: state, orchestrator: orchestrator, expanded: expanded,
                        safeTop: safe.top
                    )
                    .zIndex(3)
                }
                .position(x: left + width / 2, y: top + height / 2)
                .opacity(window.alpha)
            }
            // Publishes this window's real on-screen frame to `orchestrator.activeRect`
            // — `.global` coordinate space to match what a host's `hitTest(_:with:)`
            // uses (mirrors `RecordingBadgeView`'s identical `badgeFrame` publication).
            // Computed above from `left`/`top`/`width`/`height` directly rather than
            // read back via a `GeometryReader`, since any reader placed after
            // `.position(...)` in the modifier chain above sees `.position()`'s
            // inflated, fills-all-available-space report instead of the box's real
            // size (see `publishedActiveRect`'s own comment). `.onChange` doesn't fire
            // for the initial value, so `.onAppear` seeds it too; both defer via
            // `DispatchQueue.main.async` since publishing state synchronously during a
            // view update is invalid.
            .onAppear {
                DispatchQueue.main.async { orchestrator.activeRect = publishedActiveRect }
            }
            .onChange(of: publishedActiveRect) { newRect in
                orchestrator.activeRect = newRect
            }
            // `orchestrator.surface` is `@Published` and flipped by the orchestrator
            // itself, not by a mutation this view makes — `withAnimation` only
            // animates changes made *inside* its own closure, so it cannot reach an
            // externally-driven value. `.animation(_:value:)` is the SwiftUI
            // mechanism built for exactly this: it re-animates the whole subtree
            // above it whenever the named value changes, no matter what changed it.
            // Flutter's `Curves.easeInOutQuart` (`Cubic(0.77, 0.0, 0.175, 1.0)` in
            // `curves.dart`) drives `pip_renderer.dart`'s grow/collapse
            // `AnimatedPositioned`. The prior curve here, `(0.42, 0, 0.58, 1)`, was
            // actually Flutter's plain `Curves.easeInOut` — a different curve family
            // (cubic vs quartic) entirely, not a Quart/Cubic naming slip — so the
            // transition visibly read differently from Flutter's.
            .animation(
                floatingEaseInOutQuart(duration: Double(config.expanded.transitionMs) / 1000),
                value: orchestrator.surface
            )
            .onChange(of: orchestrator.surface) { newSurface in
                let willExpand = newSurface == .expanded
                expandedContentVisible = false
                if willExpand {
                    let delay = Double(config.expanded.transitionMs) / 1000
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if orchestrator.surface == .expanded { expandedContentVisible = true }
                    }
                }
            }
        }
        .onAppear {
            // A `startExpanded` showing is already expanded when this view is created, so
            // `.onChange(of: orchestrator.surface)` never fires for it and its canvas would
            // never mount. There is no grow transition to wait for: show it from the first frame.
            if expanded { expandedContentVisible = true }
            window.runEntry(config.collapsed.entryAnimation, fullscreen: expanded)
            // The impression is the first drawn frame, not the media load (SR62).
            orchestrator.markDrawn(token: state.token)
        }
        .onChange(of: orchestrator.closing) { closing in
            if closing { window.runExit(config.collapsed.exitAnimation, fullscreen: expanded) }
        }
        .onDisappear { orchestrator.activeRect = nil }
    }

    // MARK: - Gesture

    private func expandFromCollapsedMediaTap() {
        // A window whose player another video took plays again on a tap, expanding or not.
        if !config.behavior.tapExpands { orchestrator.showVideoAgainIfLost() }
        guard !expanded, config.behavior.tapExpands, !orchestrator.closing else { return }
        SDKInstance.shared.reportFloaterClicked(
            elementId: "pip_media", actionType: "expand", ctaRole: "primary"
        )
        orchestrator.expand()
    }
}

/// The collapsed window's size for the given screen. Height comes from exactly one source, in the
/// order the wire contract defines: an explicit `heightDp`, else the media aspect ratio, else a 9:16
/// fallback — matches Flutter's `_collapsedRect` / Android's `FloatingWindowSize.VideoAspect`.
private func collapsedWindowSize(config: FloaterConfig, screenSize: CGSize) -> CGSize {
    let width = screenSize.width * config.collapsed.widthFraction
    let ratio = config.media.aspectRatio > 0 ? config.media.aspectRatio : 0.5625
    let height = config.collapsed.hasFixedHeight ? config.collapsed.heightDp : width / ratio
    return CGSize(width: width, height: height)
}

extension Comparable {
    fileprivate func clamped(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}

// MARK: - Scrim

private struct FloaterScrimView: View {
    let opacity: Double

    var body: some View {
        // `startPoint`/`endPoint` are specified semantically (.bottom/.top), so
        // unlike Compose's default-direction `verticalGradient` (top=0/bottom=1, the
        // opposite of what this needs) there is no stop-position mirroring to get
        // wrong — strongest where the content sits, clear at the top so the
        // creative still reads.
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(opacity * 0.55), location: 0.55),
                .init(color: .black.opacity(opacity), location: 1),
            ]),
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Expanded content

/// The canvas composited over the media — drawn by the shared canvas renderer
/// (`CampaignCanvasView`), the same system nudge's canvas-layout-mode content uses.
/// **Not** `NudgeColumnContent`/`NudgeColumn` — floater's `expanded.canvas` is a
/// `CampaignCanvas`, matching Flutter's `pip_config.dart` and Android's
/// `FloaterConfig.kt` exactly; there is no separate widget-tree content model here.
private struct FloaterExpandedContentView: View {
    let state: ActiveFloaterState
    let safeAreaInsets: EdgeInsets

    private var config: FloaterExpandedConfig { state.config.expanded }

    var body: some View {
        GeometryReader { geo in
            // Mirrors Flutter's `_expandedContent`/`_expandedChromeBandHeight`: insets clear
            // of the top close/collapse pill row and the bottom safe area, then pins the
            // (naturally-sized) canvas to the bottom — a plain `.center` alignment with no
            // insets, the previous implementation here, let content authored to sit at the
            // bottom of the canvas always render vertically centered instead (matches the bug
            // found and fixed in Android's `ExpandedContent`, same underlying cause: no
            // chrome-band-aware inset was ever applied on either native platform).
            let gap: CGFloat = 8
            let pillHeight = config.iconSize * 1.6
            let topInset = safeAreaInsets.top + config.controlsMargin.top + pillHeight + gap
            let bottomInset = safeAreaInsets.bottom + gap + config.controlsMargin.bottom
            CampaignCanvasView(
                canvas: config.canvas,
                surface: floaterCanvasSurface,
                designWidth: config.designWidth,
                availableSize: geo.size,
                onAction: { request in performFloaterCanvasAction(request, state: state) },
                // Composited over the media; `expanded.backgroundColor` is drawn behind it, as on Flutter.
                showBackground: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
        }
        .environment(\.digiaVariables, state.variableContext)
        .environment(\.digiaCampaignKey, state.payload.campaignKey)
    }

    /// Mirrors Android's `NudgeSurface(displayType = DIALOG, minHorizontalMargin = 0f)`
    /// — `.dialog` (not `.bottomSheet`) so `CampaignCanvasView`'s internal scale
    /// calculation treats this as a floating surface, not a sheet.
    private var floaterCanvasSurface: NudgeSurface {
        NudgeSurface.fromJson(["displayType": "dialog", "minHorizontalMargin": 0])
    }
}

/// Runs a canvas action (a button's tap, or a tap region) and reports it as a floater
/// step click. Mirrors `NudgeOverlayView.swift`'s `performCanvasAction`, but reports
/// through `reportFloaterStepClicked` ("Digia Step Clicked") instead of
/// `emitNudgeClick` ("Digia Experience Clicked"), and — floater's own contract, which
/// nudge has no equivalent for — ends the showing once the action completes.
///
/// Deliberately unconditional, not gated on `request.actions.isEmpty` the way
/// `performCanvasAction` is: matches Android's identical floater `onAction` handler,
/// which reports and runs the (possibly empty, trivially-completing) action flow either
/// way rather than treating "no actions" as a no-op.
@MainActor
private func performFloaterCanvasAction(
    _ request: CampaignCanvasActionRequest, state: ActiveFloaterState
) {
    let resolvedAction = request.actions.first?.resolved(with: state.variableContext)
    SDKInstance.shared.reportFloaterStepClicked(
        elementId: request.elementId, ctaLabel: request.label ?? "",
        actionType: resolvedAction?.analyticsType, actionUrl: resolvedAction?.analyticsURL
    )
    Task {
        await SDKInstance.shared.executeActionFlow(
            request.actions, variables: state.variableContext,
            campaignKey: state.payload.campaignKey,
            // A dismiss authored on a CTA is the CTA taken, not the user closing it (the
            // window's × stays .userClose), as on Android and Flutter. It ends the showing
            // here, at its place in the flow; the call after the flow then finds it closing
            // and does nothing, and still ends a CTA that has no dismiss.
            localActionExecutor: LocalActionExecutor(dismiss: {
                SDKInstance.shared.onFloaterActionCompleted()
            })
        )
        SDKInstance.shared.onFloaterActionCompleted()
    }
}

// MARK: - Chrome

private struct FloaterChromeView: View {
    let state: ActiveFloaterState
    @ObservedObject var orchestrator: FloaterOrchestrator
    let expanded: Bool
    let safeTop: CGFloat

    private var config: FloaterConfig { state.config }

    var body: some View {
        if expanded {
            expandedChrome
        } else {
            collapsedChrome
        }
    }

    // MARK: Expanded

    @ViewBuilder
    private var expandedChrome: some View {
        // The swipe-down-to-collapse strip — iOS's equivalent of Android's back
        // gesture, and unconditional (not gated by controls.showCollapse): that flag
        // hides the visible button, this is a second way to reach the same outcome,
        // not a substitute for it. There is no OS-level back gesture that reaches a
        // floating in-app window on iOS, so this is the *only* back-parity mechanism
        // here, not a supplement to one.
        VStack {
            Color.clear
                .frame(height: 140)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            if value.translation.height > 120
                                || value.predictedEndTranslation.height > 700
                            {
                                SDKInstance.shared.endFloaterExpanded(config.expanded.onBack)
                            }
                        }
                )
            Spacer()
        }
        .allowsHitTesting(true)

        VStack {
            HStack {
                if config.expanded.closeOnLeft {
                    closeButton
                    Spacer()
                    trailingPill
                } else {
                    trailingPill
                    Spacer()
                    closeButton
                }
            }
            Spacer()
        }
        .padding(.top, safeTop + config.expanded.controlsMargin.top)
        .padding(.leading, config.expanded.controlsMargin.left)
        .padding(.trailing, config.expanded.controlsMargin.right)
    }

    private var expandedIconSize: CGFloat { config.expanded.iconSize }

    @ViewBuilder
    private var closeButton: some View {
        if config.expanded.showCloseButton {
            FloaterChromeCloseButton(size: expandedIconSize) {
                // No Clicked report — see FloaterEvent.Clicked's kdoc.
                SDKInstance.shared.endFloaterExpanded(config.expanded.onClose)
            }
        }
    }

    @ViewBuilder
    private var trailingPill: some View {
        FloaterChromePill(size: expandedIconSize) {
            if config.controls.showCollapse {
                FloaterChromeIcon(glyph: .fullscreenExit, size: expandedIconSize) {
                    SDKInstance.shared.reportFloaterClicked(
                        elementId: "pip_collapse", actionType: "collapse", ctaRole: "secondary"
                    )
                    orchestrator.collapse()
                }
            }
            if config.expanded.showPlaybackControls, config.media.kind.isPlayable {
                FloaterPlayPauseButton(orchestrator: orchestrator, size: expandedIconSize)
            }
            if config.expanded.showMute, config.media.kind == .video {
                FloaterMuteButton(orchestrator: orchestrator, size: expandedIconSize)
            }
        }
    }

    // MARK: Collapsed

    @ViewBuilder
    private var collapsedChrome: some View {
        // Every corner is fixed. On a window this small there is no room to move
        // controls around, and an affordance that changes place per campaign is one
        // the user has to re-find every time — authors choose whether each control
        // appears, never where.
        let collapsedIconSize = config.controls.iconSize
        let collapsedMargin = config.controls.margin
        let showsProgress = config.controls.showProgress && config.media.kind.isPlayable
        let bottomInset: CGFloat = showsProgress ? 8 : collapsedMargin.bottom
        let showsMute = config.controls.showMute && config.media.kind == .video
        let showsPlayPause = config.controls.showPlayPause && config.media.kind.isPlayable

        // Positioned via `.overlay(alignment:)` rather than a
        // `VStack{HStack{Spacer();pill};Spacer()}` pattern (the previous approach,
        // one per corner) — that pattern's `Spacer()`s expand to fill the entire
        // collapsed box, and this codebase already documents (see this file's own
        // `PreferenceKey` history) that a full-frame `VStack`/`HStack` container built
        // that way can claim hit-testing across its whole frame, not just where the
        // pill visually sits — confirmed live: whichever half of the box such a
        // container's `Spacer()` expanded into stopped responding to any touch
        // (button, drag, or tap-to-expand alike), independent of the drag/tap gesture
        // rework above. `.overlay(alignment:)`'s content sizes to its own intrinsic
        // size, not the parent's full frame, so it can't reproduce that.
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .topTrailing) {
                if config.controls.showClose {
                    FloaterChromeCloseButton(size: collapsedIconSize) {
                        // No Clicked report for the × — see FloaterEvent.Clicked's
                        // kdoc; this bug (an instant close counted as a
                        // conversion) already happened once and drove dismissal
                        // rate to a permanent 0% before it was caught.
                        SDKInstance.shared.dismissFloater(.userClose)
                    }
                    .padding(.top, collapsedMargin.top)
                    .padding(.trailing, collapsedMargin.right)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if config.controls.showExpand, config.behavior.tapExpands {
                    FloaterChromePill(size: collapsedIconSize) {
                        FloaterChromeIcon(glyph: .fullscreen, size: collapsedIconSize) {
                            SDKInstance.shared.reportFloaterClicked(
                                elementId: "pip_expand", actionType: "expand", ctaRole: "primary"
                            )
                            orchestrator.expand()
                        }
                    }
                    .padding(.leading, collapsedMargin.left)
                    .padding(.bottom, bottomInset)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsMute || showsPlayPause {
                    FloaterChromePill(size: collapsedIconSize) {
                        if showsPlayPause {
                            FloaterPlayPauseButton(
                                orchestrator: orchestrator, size: collapsedIconSize)
                        }
                        if showsMute {
                            FloaterMuteButton(orchestrator: orchestrator, size: collapsedIconSize)
                        }
                    }
                    .padding(.trailing, collapsedMargin.right)
                    .padding(.bottom, bottomInset)
                }
            }
            .overlay {
                if showsProgress {
                    FloaterProgressBarView(orchestrator: orchestrator)
                }
            }
    }
}

private struct FloaterMuteButton: View {
    @ObservedObject var orchestrator: FloaterOrchestrator
    let size: CGFloat

    var body: some View {
        FloaterChromeIcon(glyph: orchestrator.muted ? .volumeOff : .volumeUp, size: size) {
            let willMute = !orchestrator.muted
            SDKInstance.shared.reportFloaterClicked(
                elementId: willMute ? "pip_mute" : "pip_unmute",
                actionType: willMute ? "mute" : "unmute", ctaRole: "secondary"
            )
            orchestrator.setMuted(willMute)
        }
    }
}

private struct FloaterPlayPauseButton: View {
    @ObservedObject var orchestrator: FloaterOrchestrator
    let size: CGFloat

    var body: some View {
        FloaterChromeIcon(glyph: orchestrator.isPlaying ? .pause : .play, size: size) {
            SDKInstance.shared.reportFloaterClicked(
                elementId: orchestrator.isPlaying ? "pip_pause" : "pip_play",
                actionType: orchestrator.isPlaying ? "pause" : "play", ctaRole: "secondary"
            )
            orchestrator.togglePlayback()
        }
    }
}

/// A bare tappable glyph, no ripple — mirrors Flutter's plain `GestureDetector.onTap`.
/// Renders Android core's own chrome icon vectors (see `FloaterIconGlyph`) rather
/// than an SF Symbol standing in for the same concept — SF Symbols are a different
/// icon family with a different visual weight/style, so "closest available symbol"
/// read as visibly different chrome across platforms even for icons as simple as ×.
private struct FloaterChromeIcon: View {
    let glyph: FloaterIconGlyph
    let size: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if glyph.rendersAsStroke {
                    // fullscreen/fullscreenExit are open corner-arrow strokes (ported
                    // from the dashboard's lucide `Maximize2`/`Minimize2`, matched to
                    // Android core's identically-stroked vector), not closed filled
                    // shapes — filling them would render nothing, since a zero-width
                    // open path encloses no area.
                    FloaterVectorIcon(glyph: glyph)
                        .stroke(
                            Color.white,
                            style: StrokeStyle(
                                lineWidth: size * (2.5 / 24), lineCap: .round, lineJoin: .round)
                        )
                } else {
                    FloaterVectorIcon(glyph: glyph)
                        .fill(Color.white)
                }
            }
            .frame(width: size, height: size)
            // The whole icon square is the target. A `.plain` button hit-tests only what its
            // label draws, so a stroked glyph took taps on its strokes alone and a tap between
            // them — the centre of the collapse arrows — fell through to the swipe strip below.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The floater's chrome glyphs, ported byte-for-byte from Android core's own
/// `drawable/ic_*.xml` vectors (`android:pathData`) so both platforms render the
/// identical shape rather than each platform's closest built-in equivalent.
enum FloaterIconGlyph {
    case close, fullscreen, fullscreenExit, volumeUp, volumeOff, play, pause

    /// fullscreen/fullscreenExit are authored as open stroked polylines (matching
    /// Android core's `android:strokeColor`/`strokeWidth` vectors, both ported from
    /// the dashboard's lucide `Maximize2`/`Minimize2`), unlike every other glyph
    /// here, which is a closed, filled shape.
    var rendersAsStroke: Bool {
        switch self {
        case .fullscreen, .fullscreenExit: true
        case .close, .volumeUp, .volumeOff, .play, .pause: false
        }
    }

    /// SVG-mini-language path data, straight from Android's `res/drawable/*.xml`,
    /// each authored at a 24x24 `android:viewportWidth`/`viewportHeight`. Android's
    /// `pathData` syntax is the SVG path grammar itself, so `svgPath(_:)` below
    /// parses these directly with no format conversion.
    var pathData: String {
        switch self {
        case .close:
            "M18.3,7.12L16.89,5.7L12,10.58L7.11,5.7L5.7,7.12L10.59,12L5.7,16.89L7.11,18.3L12,13.41L16.89,18.3L18.3,16.89L13.41,12z"
        case .fullscreen:
            "M15,3h6v6 M21,3l-7,7 M3,21l7,-7 M9,21H3v-6"
        case .fullscreenExit:
            "M14,10l7,-7 M20,10h-6V4 M3,21l7,-7 M4,14h6v6"
        case .volumeUp:
            "M3,9v6h4l5,5V4L7,9H3zM16.5,12c0,-1.77 -1.02,-3.29 -2.5,-4.03v8.05c1.48,-0.73 2.5,-2.25 2.5,-4.02zM14,3.23v2.06c2.89,0.86 5,3.54 5,6.71s-2.11,5.85 -5,6.71v2.06c4.01,-0.91 7,-4.49 7,-8.77s-2.99,-7.86 -7,-8.77z"
        case .volumeOff:
            "M16.5,12c0,-1.77 -1.02,-3.29 -2.5,-4.03v2.21l2.45,2.45c0.03,-0.2 0.05,-0.41 0.05,-0.63zM19,12c0,0.94 -0.2,1.82 -0.54,2.64l1.51,1.51C20.63,14.91 21,13.5 21,12c0,-4.28 -2.99,-7.86 -7,-8.77v2.06c2.89,0.86 5,3.54 5,6.71zM4.27,3L3,4.27 7.73,9H3v6h4l5,5v-6.73L16.25,17.52c-0.67,0.52 -1.42,0.93 -2.25,1.18v2.06c1.38,-0.31 2.63,-0.95 3.69,-1.81L19.73,21 21,19.73 12,10.73 4.27,3zM12,4L9.91,6.09 12,8.18V4z"
        case .play:
            "M8,5v14l11,-7z"
        case .pause:
            "M6,19h4V5H6V19z M14,5v14h4V5H14z"
        }
    }

    /// Parsed once per case, at first access, and reused from then on — `svgPath(_:)`
    /// walks `pathData` character by character, which is unnecessary work to repeat
    /// on every render. This icon is a sibling inside the same box
    /// `FloaterSessionView.body` repositions, so it redraws on every single drag
    /// frame; re-parsing raw path syntax there on each of those frames was real,
    /// avoidable work sitting on the hot path and showed up as the drag no longer
    /// tracking the finger smoothly (confirmed live).
    var parsedPath: Path {
        FloaterIconGlyph.parsedPathCache[self]!
    }

    private static let parsedPathCache: [FloaterIconGlyph: Path] = Dictionary(
        uniqueKeysWithValues: [
            FloaterIconGlyph.close, .fullscreen, .fullscreenExit, .volumeUp, .volumeOff, .play,
            .pause,
        ]
        .map { ($0, svgPath($0.pathData)) }
    )
}

/// Scales `glyph`'s pre-parsed `Path` to fit whatever frame it's given, the same
/// way `Rectangle`/`Circle` do — a raw `Path` alone is sized to its 24x24 source
/// viewport and won't rescale to a `.frame(...)` on its own; only cheap geometry
/// (an affine transform), not any string parsing, happens per render here.
struct FloaterVectorIcon: Shape {
    let glyph: FloaterIconGlyph
    private let viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return glyph.parsedPath.applying(transform)
    }
}

/// Parses the subset of SVG path-data syntax Android's `VectorDrawable
/// android:pathData` uses (M/m, L/l, H/h, V/v, C/c, S/s, Z/z — every command
/// `FloaterIconGlyph`'s vectors actually contain, including implicit repeated
/// coordinate pairs after a command letter, e.g. `L a,b c,d` meaning two lineto
/// segments) into a SwiftUI `Path`. Both coordinate systems are top-left-origin,
/// Y-down, so no axis flip is needed between them.
private func svgPath(_ data: String) -> Path {
    var path = Path()
    let chars = Array(data)
    var i = 0
    let commandLetters = Set("MmLlHhVvCcSsZz")

    func skipSeparators() {
        while i < chars.count,
            chars[i] == "," || chars[i] == " " || chars[i] == "\n" || chars[i] == "\t"
        {
            i += 1
        }
    }
    func readNumber() -> CGFloat? {
        skipSeparators()
        guard i < chars.count else { return nil }
        var j = i
        if chars[j] == "-" || chars[j] == "+" { j += 1 }
        var sawDigitOrDot = false
        while j < chars.count, chars[j].isNumber || chars[j] == "." {
            sawDigitOrDot = true
            j += 1
        }
        guard sawDigitOrDot, j > i else { return nil }
        let numberString = String(chars[i..<j])
        i = j
        guard let value = Double(numberString) else { return nil }
        return CGFloat(value)
    }
    func readPoint() -> CGPoint? {
        guard let x = readNumber(), let y = readNumber() else { return nil }
        return CGPoint(x: x, y: y)
    }

    var current = CGPoint.zero
    var subpathStart = CGPoint.zero
    var lastControl: CGPoint?
    var lastCommand: Character = " "

    while i < chars.count {
        skipSeparators()
        guard i < chars.count else { break }
        let command: Character
        if commandLetters.contains(chars[i]) {
            command = chars[i]
            i += 1
        } else {
            // Implicit repeat of the previous command with no new letter — per the
            // SVG spec, a repeated M/m is treated as L/l; every other command just
            // repeats itself.
            switch lastCommand {
            case "M": command = "L"
            case "m": command = "l"
            default: command = lastCommand
            }
        }

        switch command {
        case "M", "m":
            guard let p = readPoint() else { return path }
            current = command == "m" ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
            subpathStart = current
            path.move(to: current)
        case "L", "l":
            guard let p = readPoint() else { return path }
            current = command == "l" ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
            path.addLine(to: current)
        case "H", "h":
            guard let x = readNumber() else { return path }
            current = CGPoint(x: command == "h" ? current.x + x : x, y: current.y)
            path.addLine(to: current)
        case "V", "v":
            guard let y = readNumber() else { return path }
            current = CGPoint(x: current.x, y: command == "v" ? current.y + y : y)
            path.addLine(to: current)
        case "C", "c":
            guard let c1 = readPoint(), let c2 = readPoint(), let p = readPoint() else {
                return path
            }
            let control1 = command == "c" ? CGPoint(x: current.x + c1.x, y: current.y + c1.y) : c1
            let control2 = command == "c" ? CGPoint(x: current.x + c2.x, y: current.y + c2.y) : c2
            let end = command == "c" ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
            path.addCurve(to: end, control1: control1, control2: control2)
            lastControl = control2
            current = end
        case "S", "s":
            guard let c2 = readPoint(), let p = readPoint() else { return path }
            let control2 = command == "s" ? CGPoint(x: current.x + c2.x, y: current.y + c2.y) : c2
            let end = command == "s" ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
            let control1 =
                lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) }
                ?? current
            path.addCurve(to: end, control1: control1, control2: control2)
            lastControl = control2
            current = end
        case "Z", "z":
            path.closeSubpath()
            current = subpathStart
        default:
            return path
        }
        lastCommand = command
    }
    return path
}

/// One scrim pill behind a group of chrome icons — a stadium radius means the shape
/// follows the contents for free: a lone icon renders as the circle it always was,
/// two or more as one pill, so mute-beside-collapse reads as one object rather than
/// two unrelated dots. Padding and spacing scale with `size` (0.3× / 0.55×,
/// matching `_chromePill`'s ratios exactly).
private struct FloaterChromePill<Content: View>: View {
    let size: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: size * 0.55) {
            content()
        }
        .padding(size * 0.3)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }
}

/// A lone × whose whole circle takes the tap, like the story close, not just the glyph.
private struct FloaterChromeCloseButton: View {
    let size: CGFloat
    let onTap: () -> Void

    var body: some View {
        FloaterChromePill(size: size) {
            FloaterChromeIcon(glyph: .close, size: size, onTap: onTap)
        }
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
    }
}

private struct FloaterProgressBarView: View {
    @ObservedObject var orchestrator: FloaterOrchestrator
    @State private var fraction: CGFloat = 0
    /// Polls playback position at a fixed interval rather than observing a
    /// KVO-published value — `AVPlayer` has no push-based position updates (only
    /// discrete discontinuity/state-change events), the same trade-off
    /// `AVPlayerView`'s own scrubber makes internally. 200ms keeps the bar visually
    /// smooth without measurably taxing a floater-sized playback session.
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack {
            Spacer()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.3)
                    Color.white.opacity(0.9).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 2)
        }
        .onReceive(timer) { _ in
            guard let player = orchestrator.player?.avPlayer,
                let duration = player.currentItem?.duration.seconds,
                duration.isFinite, duration > 0
            else {
                fraction = 0
                return
            }
            fraction = CGFloat((player.currentTime().seconds / duration).clamped(0, 1))
        }
    }
}
