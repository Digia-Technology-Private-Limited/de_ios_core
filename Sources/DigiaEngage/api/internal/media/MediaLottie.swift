import SwiftUI
import UIKit

internal import Lottie
internal import DigiaVideoEngine

/// The one Lottie wrapper the non-story surfaces render through: the platform composition
/// loaded through Lottie's own cache (Lottie bytes are never routed through the image cache),
/// with the authored BlurHash as the still while the animation loads and no backdrop of its own,
/// so a transparent animation stays transparent over the page.
///
/// When the load fails, and when the URL is unusable, the box shows the error placeholder
/// ("Lottie failed") and no BlurHash; `errorContent` replaces the placeholder.
/// `freezeAt` draws one frame at that progress instead of playing, for deterministic snapshots.
///
/// Health is reported once per failure, for the campaign in the environment: `invalid_url` for an
/// unusable URL (blank, an unresolved `{{variable}}`, no scheme), `http_4xx`, `decode`. A network
/// failure, a timeout or a 5xx reports nothing.
///
/// Never throws from the render path: an unusable URL shows the error placeholder without fetching.
struct MediaLottie: View {
    let url: String
    var fit: MediaFit = .cover
    var blurHash: String? = nil
    var loop: Bool = true
    var autoplay: Bool = true
    var errorContent: AnyView? = nil
    var freezeAt: CGFloat? = nil

    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.mediaServices) private var services
    @State private var source: LottieAnimationSource?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let source {
                animation(source)
            } else {
                if failed {
                    errorContent ?? AnyView(MediaErrorPlaceholder(label: "Lottie failed"))
                } else {
                    MediaStill(fit: fit, blurHash: blurHash)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            await load()
        }
    }

    @ViewBuilder
    private func animation(_ source: LottieAnimationSource) -> some View {
        // The closure form takes an already-loaded source, so a composition that parsed once is
        // never re-fetched on re-render; loading happens once per URL in `load()`.
        let view = LottieView { source }
            .resizable()
            .configure(\.contentMode, to: fit.viewContentMode)
        if let freezeAt {
            view.paused(at: .progress(freezeAt))
        } else if autoplay {
            view.playing(loopMode: loop ? .loop : .playOnce)
        } else {
            view
        }
    }

    private func load() async {
        source = nil
        failed = false
        guard let url = mediaUsableURL(url) else {
            failed = true
            services.reportHealth(campaignKey, .lottie, "invalid_url")
            return
        }
        let loaded = await services.loadLottie(url)
        guard !Task.isCancelled else { return }
        if let loadedSource = loaded.source {
            source = loadedSource
        } else {
            failed = true
            if let cause = loaded.failureCause {
                services.reportHealth(campaignKey, .lottie, cause)
            }
        }
    }
}
