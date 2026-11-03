import AVFoundation
internal import Lottie
import SwiftUI

/// The media surface, shared by both states. Reads the orchestrator's own `player` —
/// created once by `FloaterOrchestrator` (from lane B's `PlayerFactory`, pointed at a
/// range-cache item), never by this view — so playback is continuous across the
/// collapsed/expanded grow transition. This view is only ever a child of the one container
/// in `FloaterSessionView` that animates size/position; it must never itself be swapped for
/// a different view identity between states (see that file's top comment) — the media never
/// re-appears here as an `if expanded` branch for exactly that reason.
///
/// Images render through the shared `MediaImage` wrapper (D1), drawing the orchestrator's
/// warmed image with no second fetch, or animating from the warmed cache. Video and Lottie
/// keep their dedicated shells: `MediaVideo`'s take-over unconditionally re-seeks an
/// already-ready external player (dropping the decoded frame the window revealed on), and
/// both wrappers paint their own dark backdrop under transparent regions — either shifts
/// the pinned fixture pixels. Wiring those two kinds through the wrappers needs `bare` /
/// no-take-over options on the frozen wrappers (Android's `FloaterMediaSurface` has both:
/// `bare = true`, `drivePlayback = false`); see the lane report. Their bytes still travel
/// the shared path — the player reads through the range cache, Lottie through the shared
/// `loadLottieSource`, gated by `MediaPrefetch` before the window reveals.
///
/// Attribution (`digiaCampaignKey`) is set by the hosting overlay; the wrappers read it.
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
    /// The orchestrator's already-decoded image, drawn in place of a fetch.
    let preloadedImage: UIImage?

    init(
        media: FloaterMediaConfig, player: AVPlayer?, cover: Bool, resolvedUrl: String,
        preloadedImage: UIImage?
    ) {
        self.media = media
        self.player = player
        self.cover = cover
        self.resolvedUrl = resolvedUrl
        self.preloadedImage = preloadedImage
    }

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
        // Nothing here handles a load failure, by design. The orchestrator warms through
        // `MediaPrefetch` and only reveals the window once its media is decoded, and drops
        // the campaign outright when it is not — so by the time this composes, the asset
        // is already warm in the same shared cache the wrapper reads from.
        if let preloadedImage, media.kind != .gif {
            Image(uiImage: preloadedImage)
                .resizable()
                .aspectRatio(contentMode: cover ? .fill : .fit)
        } else if !resolvedUrl.isEmpty, !resolvedUrl.contains("{{") {
            MediaImage(
                spec: MediaSpec(url: resolvedUrl, fit: cover ? .cover : .contain),
                // An animated image has no single still: the wrapper draws it from
                // the warmed cache so it animates instead of freezing.
                preloaded: media.kind == .gif ? nil : preloadedImage
            )
        }
    }
}
