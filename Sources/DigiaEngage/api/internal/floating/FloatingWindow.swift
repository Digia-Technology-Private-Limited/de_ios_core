import Combine
import SwiftUI
import UIKit

// The shared floating window both floaters are drawn in.
//
// The media floater (PIP) and the story floater are separate campaigns with separate
// orchestrators, but their windows are the same object: a small box that floats over the host
// app, sits in a configured corner, drags with a finger, snaps on release, flies/fades in and
// out, and draws the same shadow. That machinery — float, drag, fling, snap, configured
// positions, entry/exit, shadow spec — lives here, extracted verbatim from
// `api/widgets/floater_overlay_view.swift` (PIP) and the window parts of
// `api/widgets/floater_story_overlay_view.swift` (story). Each surface supplies only its
// content and its size rule: the PIP window sizes from the video aspect
// (`FloatingWindowSize.videoAspect`), the story window from its configured size
// (`FloatingWindowSize.configured`).
//
// Deliberately NOT shared: the pixels. The PIP chrome pills, the story's hero aperture and
// viewer, the expanded states, and the × buttons render differently per surface (different
// shapes, different analytics), so unifying them would change what is on screen. Likewise the
// close/dismiss *dispatch* (which event is reported, which orchestrator call ends the showing)
// stays with each surface — what is shared here is the dismiss *protocol*: the exit
// animation in `runExitAnimation` and the gesture gating on `closing` at each call site.
//
// Android parity: mirrors `android/.../internal/floating/FloatingWindow.kt`
// (`FloatingWindowSize`, the resting-rect math, the drag/settle state, the snap projection,
// the ease curves). Intended iOS differences, all pixel- or behaviour-identical to what the
// two session views did before:
// - State lives in this `ObservableObject` consumed through `@StateObject` instead of
//   Compose's `rememberFloatingWindow`, because the hosts are SwiftUI views.
// - The settle spring uses `Animation.interpolatingSpring` with the same physical units as
//   the Flutter reference (mass 1, stiffness 210, damping 24), so unlike the Android port
//   this needs no dampingRatio conversion.
// - Gestures arrive through the shared UIKit shield (`FloatingWindowInteraction.swift`),
//   not a pointer-input loop — a SwiftUI `DragGesture` re-evaluating the whole body on
//   every touch-move could not keep pace with the finger (see the shield's own comment).
// - The shadow is applied directly (`.floatingWindowShadow`), not through an elevation
//   approximation: SwiftUI's `.shadow` takes the Flutter `BoxShadow` values as-is.
// - Device geometry comes from the key `UIWindow` (`FloatingWindowGeometry.swift`), not
//   from Compose insets: a `GeometryReader`'s own insets depend on how the host app
//   embedded `DigiaHost` and double-inset the window in some hosts.

/// How a surface sizes its window. The only thing a surface contributes besides its content.
enum FloatingWindowSize {
    /// The PIP rule: an explicit height wins, else the media aspect ratio, else a 9:16
    /// fallback — the order the wire contract defines.
    case videoAspect(widthFraction: CGFloat, aspectRatio: CGFloat, fixedHeightDp: CGFloat?)
    /// The story-floater rule: width is a screen fraction, height follows the authored ratio
    /// (the dashboard derives it from the window canvas's own shape).
    case configured(widthFraction: CGFloat, aspectRatio: CGFloat)

    var widthFraction: CGFloat {
        switch self {
        case let .videoAspect(widthFraction, _, _): return widthFraction
        case let .configured(widthFraction, _): return widthFraction
        }
    }

    /// The window height for the given width, per the size rule above.
    func height(forWidth width: CGFloat) -> CGFloat {
        switch self {
        case let .videoAspect(_, aspectRatio, fixedHeightDp):
            if let fixedHeightDp { return fixedHeightDp }
            let ratio = aspectRatio > 0 ? aspectRatio : 0.5625
            return width / ratio
        case let .configured(_, aspectRatio):
            return width / aspectRatio
        }
    }
}

/// Per-side spacing in points, read from the side that clears the device's safe area.
struct FloatingWindowInsets {
    let top: CGFloat
    let bottom: CGFloat
    let leading: CGFloat
    let trailing: CGFloat

    init(_ insets: EdgeInsets) {
        top = insets.top
        bottom = insets.bottom
        leading = insets.leading
        trailing = insets.trailing
    }

    init(_ insets: UIEdgeInsets) {
        top = insets.top
        bottom = insets.bottom
        leading = insets.left
        trailing = insets.right
    }
}

func floatingClamped<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}

/// The window's resting rect for the given screen size. Margins apply inside the safe area,
/// so a top-corner window clears the status bar/notch and a bottom one clears the home
/// indicator. A `dragFraction` (the last committed snap position) overrides the configured
/// corner; either way the result is clamped back inside the margins, so a window larger
/// than the free space still lands somewhere drawable instead of off-screen.
func floatingRestingRect(
    size: FloatingWindowSize,
    screenSize: CGSize,
    safeInsets: FloatingWindowInsets,
    margin: FloaterMargin,
    position: FloaterCorner,
    dragFraction: FloaterFraction?
) -> CGRect {
    let width = screenSize.width * size.widthFraction
    let height = size.height(forWidth: width)

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
        left = position.isRight ? maxX : minX
        top = position.isBottom ? maxY : minY
    }
    let clampedMaxX = maxX < minX ? minX : maxX
    let clampedMaxY = maxY < minY ? minY : maxY
    return CGRect(
        x: floatingClamped(left, minX, clampedMaxX),
        y: floatingClamped(top, minY, clampedMaxY),
        width: width, height: height
    )
}

/// The window's drag/fling/snap and entry/exit state, shared by both session views.
///
/// The views keep their own guards (expanded/story-open/closing/draggable are surface
/// concerns) and call in here for the mechanics, which are identical: a 6 pt slop before a
/// touch becomes a drag, an unclamped mirror of the finger while it moves (the rubber-band
/// feel — the clamp lives in `floatingRestingRect` at release), and a spring back to the
/// committed corner carrying the visual position across as a residual so the window never
/// teleports.
@MainActor
final class FloatingWindow: ObservableObject {
    /// Touches under this distance are taps, not drags — the same slop both sessions used.
    private static let dragThreshold: CGFloat = 6
    /// How far ahead of the finger the release projects when snapping: a quick flick often
    /// ends before the window visually crosses the half-way line. Matches the shield's own
    /// `velocity * 0.18` projection so the snap target and the gesture agree.
    private static let snapProjectionSeconds: CGFloat = 0.18

    @Published var dragTranslation = CGSize.zero
    @Published var isDragging = false
    @Published var settleResidual = CGSize.zero
    @Published var alpha = 1.0
    @Published var flyOffsetFraction = CGSize.zero

    /// The visual offset while no finger is down: the in-flight drag, else the settle
    /// spring's residual.
    var restingDelta: CGSize { isDragging ? dragTranslation : settleResidual }

    /// Records one touch-move. A new touch beats an in-flight spring: grabbing the window
    /// mid-bounce takes control immediately instead of fighting it.
    func dragChanged(_ translation: CGSize) {
        guard !isDragging else {
            dragTranslation = translation
            return
        }
        guard hypot(translation.width, translation.height) > Self.dragThreshold else { return }
        isDragging = true
        settleResidual = .zero
        dragTranslation = translation
    }

    /// Lands the release: snaps (or free-drops) to a corner fraction, commits it through
    /// `onCommit`, then carries the visual position across as a residual and lets the
    /// spring pull it in — otherwise the window would teleport and only then animate.
    func dragEnded(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        resting: CGRect,
        screenSize: CGSize,
        safeInsets: FloatingWindowInsets,
        margin: FloaterMargin,
        draggable: Bool,
        snapToCorner: Bool,
        onCommit: (FloaterFraction) -> Void
    ) {
        guard draggable, isDragging,
            hypot(translation.width, translation.height) > Self.dragThreshold
        else {
            isDragging = false
            dragTranslation = .zero
            return
        }
        let minX = safeInsets.leading + margin.left
        let maxX = screenSize.width - safeInsets.trailing - margin.right - resting.width
        let minY = safeInsets.top + margin.top
        let maxY = screenSize.height - safeInsets.bottom - margin.bottom - resting.height
        let spanX = maxX - minX
        let spanY = maxY - minY

        let visualLeft = resting.minX + translation.width
        let visualTop = resting.minY + translation.height

        var fx: CGFloat =
            spanX <= 0 ? 0 : floatingClamped((visualLeft - minX) / spanX, 0, 1)
        var fy: CGFloat =
            spanY <= 0 ? 0 : floatingClamped((visualTop - minY) / spanY, 0, 1)
        if snapToCorner {
            // The *projected* end of the flick, not where the finger left off.
            let projectedLeft = resting.minX + predictedEndTranslation.width
            let projectedTop = resting.minY + predictedEndTranslation.height
            let projectedFx: CGFloat =
                spanX <= 0 ? 0 : floatingClamped((projectedLeft - minX) / spanX, 0, 1)
            let projectedFy: CGFloat =
                spanY <= 0 ? 0 : floatingClamped((projectedTop - minY) / spanY, 0, 1)
            fx = projectedFx >= 0.5 ? 1 : 0
            fy = projectedFy >= 0.5 ? 1 : 0
        }
        let landingX = spanX <= 0 ? minX : minX + spanX * fx
        let landingY = spanY <= 0 ? minY : minY + spanY * fy

        onCommit(FloaterFraction(x: fx, y: fy))
        isDragging = false
        dragTranslation = .zero
        settleResidual = CGSize(width: visualLeft - landingX, height: visualTop - landingY)
        withAnimation(floatingSettleSpring) {
            settleResidual = .zero
        }
    }

    /// Runs the entry animation. `alreadyVisible` covers the PIP's expanded showing, which
    /// is already full-screen and needs no arrival.
    func runEntryAnimation(entry: FloaterEntryAnimation, alreadyVisible: Bool) {
        if alreadyVisible || entry.type == .appear {
            alpha = 1
            return
        }
        alpha = 0
        let flies = entry.type == .flyIn
        flyOffsetFraction = flies ? floatingFlyOffset(entry.from) : .zero
        let duration = Double(entry.durationMs) / 1000
        withAnimation(
            flies ? floatingEaseOutBack(duration: duration)
                : floatingEaseOutCubic(duration: duration)
        ) {
            alpha = 1
            flyOffsetFraction = .zero
        }
    }

    /// Runs the exit animation. `skipWhenCovered` covers the PIP's expanded showing: the
    /// content is already full-screen, so there is nothing to fly or fade away.
    func runExitAnimation(exit: FloaterExitAnimation, skipWhenCovered: Bool) {
        guard exit.type != .none, !skipWhenCovered else { return }
        let flies = exit.type == .flyOut
        let duration = Double(exit.durationMs) / 1000
        withAnimation(
            flies ? floatingEaseOutCubic(duration: duration) : floatingEaseIn(duration: duration)
        ) {
            alpha = 0
            if flies { flyOffsetFraction = floatingFlyOffset(exit.to) }
        }
    }
}

/// The shadow both floaters draw, from Flutter's
/// `BoxShadow(color: Color(0x73000000), blurRadius: 24, offset: Offset(0, 8))`.
/// Unlike the Android port (no directly-offset drop-shadow modifier, so an 8 dp elevation
/// reads at roughly the same weight), SwiftUI's `.shadow` takes the Flutter values as-is:
/// 0.45 opacity, 12 pt blur, 8 pt down.
extension View {
    /// Same "cheap no-op instead of a different view" shape both sessions already used:
    /// switching view identity on a flag would pop the shadow instead of animating it.
    func floatingWindowShadow(applied: Bool) -> some View {
        shadow(
            color: applied ? Color.black.opacity(0.45) : .clear,
            radius: applied ? 12 : 0,
            x: 0,
            y: applied ? 8 : 0
        )
    }
}

/// Prepare-then-show seam for floating surfaces (T8 merge note).
///
/// Floating surfaces warm media first, then show; inline surfaces show immediately with a
/// poster/BlurHash instead (issue #157, user story 12). The window itself never fetches —
/// the orchestrators gate the first frame on readiness today (`awaitingMedia`), and lane H
/// (T12) rewires that path onto lane C's real `MediaPrefetch`, which hands back finished
/// images so the window shows only when loaded.
///
/// Lane C owns the `MediaPrefetch` protocol (`media/MediaPrefetch*` — do NOT create those
/// files here). Until it merges, this is the narrowest local closure over what the window
/// needs: warm the given URLs through the shared cache, report readiness. Lane H swaps this
/// alias for the real protocol without touching the window.
typealias FloatingMediaWarmup = @Sendable (_ urls: [URL]) async -> Bool
