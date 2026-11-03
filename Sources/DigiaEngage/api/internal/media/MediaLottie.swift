import SwiftUI
import UIKit

internal import Lottie

/// The one Lottie wrapper every surface renders through (D1): the platform composition loaded
/// through Lottie's own cache (`loadLottieSource` — Lottie bytes are never routed through the
/// image cache, D6), over the shared dark backdrop with the authored BlurHash as the still (D5),
/// so a missing or broken file leaves the still instead of an empty box.
///
/// A load failure — network ones included — is reported through the media health hook with a
/// non-nil cause (D5), and the still stays regardless.
///
/// Never throws from the render path: a blank, templated or otherwise unusable URL degrades to
/// the still without fetching and without reporting.
struct MediaLottie: View {
    let spec: MediaSpec
    /// The fetch or parse failed. The argument is the same non-nil cause sent to health.
    var onFailure: ((String) -> Void)? = nil

    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.mediaServices) private var services
    @State private var source: LottieAnimationSource?

    private let blurStill: UIImage?

    init(spec: MediaSpec, onFailure: ((String) -> Void)? = nil) {
        self.spec = spec
        self.onFailure = onFailure
        self.blurStill = spec.blurHash.flatMap { BlurHashDecoder.decode($0, width: 32, height: 32) }
    }

    var body: some View {
        ZStack {
            Color.mediaBackdrop
            if let blurStill {
                if let mode = spec.fit.contentMode {
                    Image(uiImage: blurStill)
                        .resizable()
                        .aspectRatio(contentMode: mode)
                } else {
                    Image(uiImage: blurStill)
                        .resizable()
                }
            }
            if let source {
                if spec.autoplay {
                    lottie(source).playing(loopMode: spec.loop ? .loop : .playOnce)
                } else {
                    lottie(source)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: spec.url) {
            await load()
        }
    }

    private func lottie(_ source: LottieAnimationSource) -> LottieView<EmptyView> {
        // The closure form below takes an already-loaded source, so a composition that parsed
        // once is never re-fetched on re-render; loading happens once per URL in `load()`.
        LottieView { source }
            .resizable()
            .configure(\.contentMode, to: spec.fit.viewContentMode)
    }

    private func load() async {
        guard let url = mediaUsableURL(spec.url) else { return }
        let loaded = await loadLottieSource(url)
        if loaded.source != nil {
            source = loaded.source
        } else {
            // D5: every failure, network ones included, reports with a non-nil cause (see
            // MediaImage's onFailure for why the fallback is "network").
            let cause = loaded.failureCause ?? "network"
            services.reportHealth(campaignKey, .lottie, cause)
            onFailure?(cause)
        }
    }
}
