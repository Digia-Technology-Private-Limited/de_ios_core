import AVFoundation
import SwiftUI

/// The media surface, shared by both states. Reads the orchestrator's own `player` —
/// created once by `FloaterOrchestrator`, never by this view — so playback is
/// continuous across the collapsed/expanded grow transition. This view is only ever
/// a child of the one container in `FloaterSessionView` that animates size/position;
/// it must never itself be swapped for a different view identity between states (see
/// that file's top comment) — the media never re-appears here as an `if expanded`
/// branch for exactly that reason.
///
/// Video reuses `InlineStoryPlayerLayer` (`DigiaInlineStoryView.swift`) — the
/// existing raw `AVPlayerLayer`/`layerClass` shim, chosen over `NudgeVideoView`'s
/// `AVPlayerViewController` wrapper because floater draws its own chrome and needs
/// the bare layer, not a controller with its own playback UI (see
/// `ai_docs/pip-campaign-design.md` §4.4's corrected citation).
struct FloaterMediaView: View {
    let media: FloaterMediaConfig
    let player: AVPlayer?
    let cover: Bool
    let resolvedUrl: String

    var body: some View {
        switch media.kind {
        case .video:
            if let player {
                InlineStoryPlayerLayer(player: player, gravity: cover ? .resizeAspectFill : .resizeAspect)
            }
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
        // The orchestrator only reveals the window once its media has loaded into the cache
        // `MediaImage` reads, and drops the campaign outright when it could not, so a failure
        // here is rare, and shows the flat black the window showed before the wrapper.
        if !resolvedUrl.isEmpty, !resolvedUrl.contains("{{") {
            MediaImage(url: resolvedUrl, fit: cover ? .cover : .contain, errorContent: AnyView(Color.black))
        }
    }
}
