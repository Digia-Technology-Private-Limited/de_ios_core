import SwiftUI

/// The upscale a floating dialog already stops at. Bottom sheets and
/// full-screen canvases stop at the same cap on a large screen, mirroring
/// Android's `MAX_LARGE_SCREEN_UPSCALE`.
internal let maxLargeScreenUpscale: CGFloat = 1.15

/// Shortest-side breakpoint for a large screen, in points. Below it the device
/// is a phone in any orientation; at or above it, a tablet (or an unfolded
/// foldable on Android). Mirrors Material's compact-width breakpoint.
internal let largeScreenMinShortestSide: CGFloat = 600

/// Whether the window counts as a large screen: a regular horizontal size
/// class (iPad full-width / Stage Manager) or a shortest side of at least
/// 600pt. Pure so unit tests can pin it without hosting a view.
internal func isLargeScreen(
    shortestSide: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?
) -> Bool {
    if horizontalSizeClass == .regular { return true }
    guard shortestSide.isFinite else { return false }
    return shortestSide >= largeScreenMinShortestSide
}

/// Width of a bottom sheet in points. Phones keep the full screen width. On a
/// large screen a full-width sheet scales its canvas past the screen height,
/// so the sheet takes the dialog's width instead. Mirrors Android's
/// `nudgeSheetWidth`.
internal func nudgeSheetWidth(
    screenWidth: CGFloat,
    designWidth: CGFloat,
    largeScreen: Bool
) -> CGFloat {
    guard largeScreen else { return screenWidth }
    return min(screenWidth, max(designWidth, 1) * maxLargeScreenUpscale)
}

/// Scale of a full-screen canvas. A phone covers the viewport with it. On a
/// large screen covering upscales the design far past its authored size and
/// crops it, so it is fitted whole at the dialog's cap and centred on its
/// full-bleed background. Mirrors Android's `fullScreenCanvasScale`.
///
/// Degrades to covering the viewport when the inputs are degenerate rather
/// than returning a non-positive scale (a render path must never vanish).
internal func fullScreenCanvasScale(
    authoredWidth: CGFloat,
    authoredHeight: CGFloat,
    viewportScale: CGFloat,
    availableWidth: CGFloat,
    availableHeight: CGFloat,
    largeScreen: Bool
) -> CGFloat {
    func coverFallback() -> CGFloat {
        max(
            availableWidth / max(authoredWidth, 1),
            availableHeight / max(authoredHeight, 1)
        )
    }
    guard authoredWidth > 0, authoredHeight > 0,
          viewportScale.isFinite, viewportScale > 0,
          availableWidth.isFinite, availableHeight.isFinite
    else { return coverFallback() }
    let designScale = largeScreen ? min(viewportScale, maxLargeScreenUpscale) : viewportScale
    let widthFit = availableWidth / max(authoredWidth * designScale, 1)
    let heightFit = availableHeight / max(authoredHeight * designScale, 1)
    let result: CGFloat
    if largeScreen {
        result = designScale * min(1, widthFit, heightFit)
    } else {
        result = designScale * max(widthFit, heightFit)
    }
    guard result.isFinite, result > 0 else { return coverFallback() }
    return result
}
