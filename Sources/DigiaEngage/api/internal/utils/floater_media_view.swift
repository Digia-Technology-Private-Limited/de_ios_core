import SwiftUI

/// The PIP window's content, shared by both states. This view is only ever a child of the one
/// container in `FloaterSessionView` that animates size and position; it must never itself be
/// swapped for a different view identity between states (see that file's top comment), so the
/// media never re-appears here as an `if expanded` branch.
///
/// Video is a `MediaVideo` borrowing the showing's player from the pool under `videoPlayerKey`,
/// the key `FloaterOrchestrator` already holds for its warm-up: the window joins that held player
/// (same item, same playhead), so growing, collapsing or a remount never restarts it (N2). It is
/// an on-screen borrow, so a full pool makes an extra player rather than refuse (OD-1). Mute, volume
/// and loop are the content's; errors after the window is shown are `MediaVideo`'s (OD-4).
struct FloaterMediaView: View {
    let media: FloaterMediaConfig
    let videoPlayerKey: String
    let muted: Bool
    let cover: Bool
    let resolvedUrl: String
    /// The orchestrator's already-decoded image, drawn in place of a `WebImage` load.
    let preloadedImage: UIImage?

    var body: some View {
        switch media.kind {
        case .video:
            MediaVideo(
                url: resolvedUrl,
                fit: cover ? .cover : .contain,
                loop: media.loop,
                muted: muted,
                volume: media.volume,
                autoplay: media.autoplay,
                // A letterbox shows the window's own ground (the expanded background), as on `main`.
                groundAfterFirstFrame: .clear,
                playerKey: videoPlayerKey,
                poolPriority: .onScreen
            )
        case .lottie:
            lottieView
        case .image, .gif:
            imageView
        }
    }

    @ViewBuilder
    private var lottieView: some View {
        if !resolvedUrl.isEmpty, !resolvedUrl.contains("{{") {
            MediaLottie(
                url: resolvedUrl,
                fit: cover ? .cover : .contain,
                loop: media.loop,
                autoplay: media.autoplay
            )
        }
    }

    @ViewBuilder
    private var imageView: some View {
        // Nothing here handles a load failure, by design. The orchestrator only
        // reveals the window once its media is decoded, and drops the campaign
        // outright when it is not — so by the time this composes, the asset is
        // already fetchable (though not necessarily SDWebImage-cache-warm; see
        // FloaterOrchestrator.preloadImage's kdoc on the plain-URLSession trade-off).
        if let preloadedImage {
            Image(uiImage: preloadedImage)
                .resizable()
                .aspectRatio(contentMode: cover ? .fill : .fit)
        } else if !resolvedUrl.isEmpty, !resolvedUrl.contains("{{") {
            MediaImage(url: resolvedUrl, fit: cover ? .cover : .contain)
        }
    }
}
