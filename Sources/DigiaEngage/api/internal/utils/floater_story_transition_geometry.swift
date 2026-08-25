import SwiftUI

/// The geometry behind the window↔story transition.
///
/// `hero` grows a *box* from the window's rect to the full screen — `floaterStoryHeroRect` — and
/// the story is drawn inside it, at its final full-screen size the whole way. The box is an
/// aperture widening onto the story UI; the content is visible immediately inside the collapsed
/// aperture, then the aperture grows to the screen.
///
/// Two earlier shapes were wrong and are worth naming, because both are the obvious thing to try.
/// Scaling a presented viewer re-renders a video, a canvas stage and a chrome layer on every frame
/// — that stutters — and *stretches* all three on the way, the exact glitch the PiP's own comment
/// warns about. Withholding or fading the story until the box lands fixes both, but splits one
/// motion into two events: a black box arrives, and then a story appears in it. An aperture has
/// neither problem — nothing is scaled, and nothing waits.
///
/// Both are driven by one phase, 0 = the window, 1 = full screen. The Android SDK's
/// `FloaterStoryTransitionGeometry.kt` is the same arithmetic; the two are meant to stay in step.

/// The transform applied to the viewer itself. Hero is driven by the aperture, so this is identity.
struct FloaterStoryTransform: Equatable {
    var alpha: CGFloat = 1
    var translationY: CGFloat = 0

    /// The settled, full-screen state.
    static let identity = FloaterStoryTransform()
}

private func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat { from + (to - from) * t }

/// The viewer's transform at `phase`.
///
/// The viewer is laid out at full screen for the whole transition and it is the box around it that
/// moves (see `floaterStoryHeroRect`), so transforming the viewer as well would be a second,
/// contradictory animation.
func floaterStoryTransform(
    type: FloaterStoryTransitionType,
    phase: CGFloat,
    screen: CGSize
) -> FloaterStoryTransform {
    let t = min(max(phase, 0), 1)
    if t >= 1 { return .identity }
    switch type {
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
/// The story is visible from the first hero frame: tapping the collapsed window first reveals the
/// expanded/story UI inside that same small aperture, then the aperture grows. Fading the content
/// in left the aperture showing only its black backing at the start of the animation.
func floaterStoryContentAlpha(type: FloaterStoryTransitionType, phase: CGFloat) -> CGFloat {
    switch type {
    case .hero:
        return 1
    }
}

/// How opaque the small window is at `phase`.
///
/// Fades it out over the first half, while the growing box — which starts on exactly the same rect
/// — takes over from it.
func floaterStoryWindowAlpha(type: FloaterStoryTransitionType, phase: CGFloat) -> CGFloat {
    let t = min(max(phase, 0), 1)
    switch type {
    case .hero:
        return min(max(1 - t * 2, 0), 1)
    }
}
