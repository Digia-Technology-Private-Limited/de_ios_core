import SwiftUI

/// The geometry behind the window↔story transition.
///
/// The two transitions are built differently on purpose, and the difference is the whole reason
/// this file exists rather than one `scaleEffect`:
///
///  * **`hero`** grows a *box* from the window's rect to the full screen — `floaterStoryHeroRect` —
///    and the story is drawn inside it, at its final full-screen size the whole way, fading up as
///    the box opens (`floaterStoryContentAlpha`). The box is an aperture widening onto a story that
///    never moves, which is the PiP's own structure — it too grows a box and renders into it.
///
///    Two earlier shapes were wrong and are worth naming, because both are the obvious thing to
///    try. Scaling a presented viewer re-renders a video, a canvas stage and a chrome layer on
///    every frame — that stutters — and *stretches* all three on the way, the exact glitch the
///    PiP's own comment warns about. Withholding the story until the box lands fixes both, but
///    splits one motion into two events: a black box arrives, and then a story appears in it. An
///    aperture has neither problem — nothing is scaled, and nothing waits.
///  * **`slideUp`** does move the presented viewer, via `floaterStoryTransform`. A pure translation
///    distorts nothing, so there is no reason to hide the content — a story sliding up from the
///    bottom edge is the whole point of the transition.
///
/// Both are driven by one phase, 0 = the window, 1 = full screen. The Android SDK's
/// `FloaterStoryTransitionGeometry.kt` is the same arithmetic; the two are meant to stay in step.

/// The transform applied to the viewer itself. Only `slideUp` uses one.
struct FloaterStoryTransform: Equatable {
    var alpha: CGFloat = 1
    var translationY: CGFloat = 0

    /// The settled, full-screen state.
    static let identity = FloaterStoryTransform()
}

private func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat { from + (to - from) * t }

/// The viewer's transform at `phase`.
///
/// `hero` never has one: the viewer is laid out at full screen for the whole transition and it is
/// the box around it that moves (see `floaterStoryHeroRect`), so transforming the viewer as well
/// would be a second, contradictory animation.
func floaterStoryTransform(
    type: FloaterStoryTransitionType,
    phase: CGFloat,
    screen: CGSize
) -> FloaterStoryTransform {
    let t = min(max(phase, 0), 1)
    if t >= 1 { return .identity }
    switch type {
    case .slideUp:
        return FloaterStoryTransform(translationY: lerp(screen.height, 0, t))
    case .hero:
        return .identity
    }
}

/// The growing box, at `phase` — the window's rect at 0, the whole screen at 1.
///
/// The box is the transition: it starts exactly where the window is, so there is no jump when the
/// window fades out behind it, and it ends exactly where the story will be, so there is no jump
/// when the story replaces it.
func floaterStoryHeroRect(window: CGRect, screen: CGSize, phase: CGFloat) -> CGRect {
    let t = min(max(phase, 0), 1)
    let left = lerp(window.minX, 0, t)
    let top = lerp(window.minY, 0, t)
    return CGRect(
        x: left,
        y: top,
        width: lerp(window.maxX, screen.width, t) - left,
        height: lerp(window.maxY, screen.height, t) - top
    )
}

/// The growing box's corner radius.
///
/// Squares off as it grows, because a full-screen story has no rounded corners and arriving at one
/// only to have it snap flat is a worse tell than never rounding at all. The PiP does the same.
func floaterStoryHeroCornerRadius(windowRadius: CGFloat, phase: CGFloat) -> CGFloat {
    windowRadius * (1 - min(max(phase, 0), 1))
}

/// How opaque the story's own content is at `phase`.
///
/// A hero fades it up *while* the box is still growing, rather than switching it on once the box
/// lands. Waiting reads as two events — a black box arrives, then a story appears in it — where the
/// whole point of the motion is that they are one.
///
/// The ramp is deliberately not the full span. It starts a little after the box does, so the first
/// frames are unambiguously the window opening rather than a cross-fade, and finishes a little
/// before the box arrives, so the story is already settled when the movement stops.
///
/// A slide needs none of this: the story is fully drawn the whole way, and it is the story itself
/// that travels.
func floaterStoryContentAlpha(type: FloaterStoryTransitionType, phase: CGFloat) -> CGFloat {
    let t = min(max(phase, 0), 1)
    switch type {
    case .hero:
        return min(max((t - 0.15) / 0.55, 0), 1)
    case .slideUp:
        return 1
    }
}

/// How opaque the small window is at `phase`.
///
/// A hero fades it out over the first half, while the growing box — which starts on exactly the
/// same rect — takes over from it. A slide passes *over* the window instead, so the window stays
/// put until it is covered; fading it early would show the host app through a hole for the length
/// of the slide.
func floaterStoryWindowAlpha(type: FloaterStoryTransitionType, phase: CGFloat) -> CGFloat {
    let t = min(max(phase, 0), 1)
    switch type {
    case .hero:
        return min(max(1 - t * 2, 0), 1)
    case .slideUp:
        return t >= 1 ? 0 : 1
    }
}
