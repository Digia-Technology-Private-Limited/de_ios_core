import AVFoundation
import SwiftUI

/// One canvas story in the viewer (T10): the page's media with the authored overlay drawn over
/// it. The media is the same borrowed player (video) or image a classic page shows; only the
/// overlay is canvas-specific. Mirrors Android `CanvasStoryPage`.
@MainActor
struct CanvasStoryPage<Overlay: View>: View {
    let item: StoryItemConfig
    let pageKey: String
    let muted: Bool
    let playing: Bool
    let onReady: @MainActor @Sendable (AVPlayer?) -> Void
    let onProgress: @MainActor @Sendable (Double) -> Void
    let onEnded: @MainActor @Sendable () -> Void
    let onBuffering: @MainActor @Sendable (Bool) -> Void
    let onFailed: @MainActor @Sendable () -> Void
    @ViewBuilder let overlay: () -> Overlay

    var body: some View {
        ZStack {
            if item.type == .video {
                VideoStoryPage(
                    item: item,
                    pageKey: pageKey,
                    muted: muted,
                    playing: playing,
                    onReady: onReady,
                    onProgress: onProgress,
                    onEnded: onEnded,
                    onBuffering: onBuffering,
                    onFailed: onFailed
                )
            } else {
                ImageStoryPage(item: item, onReady: { onReady(nil) })
            }
            overlay()
        }
    }
}
