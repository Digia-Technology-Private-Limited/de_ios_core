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
/// warns about. Withholding the story until the box lands avoids that transform, but exposes the
/// aperture's black backing during both expand and collapse. Keeping a full-size media surface
/// behind the aperture avoids both problems: nothing is scaled, and nothing waits. Full-screen
/// overlays are added only after the aperture lands.
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

/// How opaque the story media aperture is at `phase`.
///
/// It reaches full opacity before the floating canvas begins fading. In reverse, the canvas is
/// therefore fully visible before the aperture disappears, so unmounting the viewer cannot cause
/// a final-frame snap.
func floaterStoryHeroAlpha(type: FloaterStoryTransitionType, phase: CGFloat) -> CGFloat {
    let t = min(max(phase, 0), 1)
    switch type {
    case .hero:
        return min(max(t * 4, 0), 1)
    }
}

/// How opaque the small window is at `phase`.
///
/// It remains fully visible until the story media aperture is opaque, then fades during the next
/// quarter of the transition. The reverse order produces a continuous collapse handoff.
func floaterStoryWindowAlpha(type: FloaterStoryTransitionType, phase: CGFloat) -> CGFloat {
    let t = min(max(phase, 0), 1)
    switch type {
    case .hero:
        return min(max((0.5 - t) * 4, 0), 1)
    }
}
