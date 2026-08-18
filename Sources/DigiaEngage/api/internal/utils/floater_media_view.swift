import AVFoundation
@_implementationOnly import Lottie
@_implementationOnly import SDWebImageSwiftUI
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
        if !resolvedUrl.isEmpty, !resolvedUrl.contains("{{"), let url = URL(string: resolvedUrl) {
            Group {
                if media.autoplay {
                    lottie(url: url).playing(loopMode: media.loop ? .loop : .playOnce)
                } else {
                    lottie(url: url)
                }
            }
        }
    }

    private func lottie(url: URL) -> LottieView<EmptyView> {
        LottieView {
            if url.pathExtension.lowercased() == "lottie" {
                return try await DotLottieFile.loadedFrom(url: url).animationSource
            }
            return await LottieAnimation.loadedFrom(url: url)?.animationSource
        }
            .resizable()
            .configure(\.contentMode, to: cover ? .scaleAspectFill : .scaleAspectFit)
    }

    @ViewBuilder
    private var imageView: some View {
        // Nothing here handles a load failure, by design. The orchestrator only
        // reveals the window once its media is decoded, and drops the campaign
        // outright when it is not — so by the time this composes, the asset is
        // already fetchable (though not necessarily SDWebImage-cache-warm; see
        // FloaterOrchestrator.preloadImage's kdoc on the plain-URLSession trade-off).
        if !resolvedUrl.isEmpty, !resolvedUrl.contains("{{"), let url = URL(string: resolvedUrl) {
            WebImage(url: url) { $0.resizable() } placeholder: { Color.black }
                .aspectRatio(contentMode: cover ? .fill : .fit)
        }
    }
}
