import AVFoundation
import SwiftUI

internal import DigiaVideoEngine

/// One video story in the viewer (T8): the page's player through `MediaVideo` on the pool, at the
/// on-screen rank, over the page's still.
///
/// Borrows under `pageKey`, the key a playing rail card hands over on tap, so the viewer gets the
/// same player with the same item (no reload, no black frame: the still covers until the layer
/// is ready). `startMs` is where it starts: 0 for a first showing, a replay or a page whose video
/// ended; nil resumes the pool's playhead (a swipe back, N9). A failure shows the still and tells
/// the viewer (`onFailure`), which runs the page's own time; a lost player does the same
/// (`onLost`). Mirrors Android `VideoStoryPage`.
@MainActor
struct VideoStoryPage: View {
    let item: StoryItemConfig
    let pageKey: String
    let muted: Bool
    let playing: Bool
    let startMs: Int64?
    /// What a letterbox shows after the first frame (OD-18).
    var groundAfterFirstFrame: Color = .black
    let onReady: (DigiaVideoPlayer) -> Void
    let onEnded: () -> Void
    let onFailure: () -> Void
    let onLost: () -> Void

    var body: some View {
        ZStack {
            Color.black
            StoryVideoSurface(
                item: item,
                fit: item.boxFit,
                stillFit: item.boxFit,
                poolKey: pageKey,
                priority: .viewerPage,
                muted: muted,
                playing: playing,
                groundAfterFirstFrame: groundAfterFirstFrame,
                startMs: startMs,
                onReady: onReady,
                onEnded: onEnded,
                onFailure: onFailure,
                onLost: onLost
            )
        }
    }
}
