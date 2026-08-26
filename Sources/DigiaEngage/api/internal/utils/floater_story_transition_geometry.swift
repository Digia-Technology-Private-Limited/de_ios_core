import SwiftUI

/// The geometry behind the window↔story transition.
///
/// `hero` grows a *box* from the window's rect to the full screen — `floaterStoryHeroRect`.
/// The box is an aperture that grows first; the story UI itself is mounted only after the
/// aperture has reached full screen.
///
/// Two earlier shapes were wrong and are worth naming, because both are the obvious thing to try.
/// Scaling a presented viewer re-renders a video, a canvas stage and a chrome layer on every frame
/// — that stutters — and *stretches* all three on the way, the exact glitch the PiP's own comment
/// warns about. The viewer therefore is not transformed with the box; it appears only after the
/// hero has landed.
///
/// Both are driven by one phase, 0 = the window, 1 = full screen. The Android SDK's
/// `FloaterStoryTransitionGeometry.kt` is the same arithmetic; the two are meant to stay in step.

private func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat { from + (to - from) * t }

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
