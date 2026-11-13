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
                // The window owns the ground: its own background shows between ready and the first
                // frame (no #1A1A1A backdrop, no spinner: OD-20) and letterboxes the video after
                // it (the expanded background), as on `main`.
                bare: true,
                playerKey: videoPlayerKey,
                poolPriority: .onScreen,
                // The orchestrator drives the held player: the window never waits for another one
                // (OD-24).
                waitsForPlayer: false
            )
        case .lottie:
            lottieView
        case .image, .gif:
            imageView
        }
    }

    private var lottieView: some View {
        MediaLottie(
            url: resolvedUrl,
            fit: cover ? .cover : .contain,
            loop: media.loop,
            autoplay: media.autoplay
        )
    }

    private var imageView: some View {
        // The orchestrator only reveals the window once its media has loaded into the cache
        // `MediaImage` reads, and drops the campaign outright when it could not, so a failure
        // here is rare, and leaves the box empty.
        MediaImage(url: resolvedUrl, fit: cover ? .cover : .contain)
    }
}
