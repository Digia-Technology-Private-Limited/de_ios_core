import SwiftUI
import UIKit

internal import SDWebImageSwiftUI

/// The one image wrapper the non-story surfaces render through: SDWebImage via the shared cache
/// and downloader (GIF and SVG decoding as before), with the authored BlurHash drawn through
/// the image library's own loading and error slots, so it is gone once the picture draws (a
/// transparent or letterboxed picture never shows a stale blur) and the box is never empty
/// before that. There is no spinner.
///
/// `errorContent` is drawn over the still when the load fails and when the URL is unusable
/// (blank, an unresolved `{{variable}}`, no scheme): surfaces that labelled a failed image keep
/// their label. The tint applies to the picture only.
///
/// Health is reported once per failure, for the campaign in the environment: `invalid_url` for
/// an unusable URL, `http_4xx`, `decode`. A network failure, a timeout or a 5xx reports nothing.
///
/// Never throws from the render path: an unusable URL shows the still without fetching.
struct MediaImage: View {
    let spec: ImageSpec
    var tintColor: Color? = nil
    /// The picture drew.
    var onSuccess: (() -> Void)? = nil
    /// The load failed or the URL is unusable (health is already reported).
    var onFailure: (() -> Void)? = nil
    var errorContent: AnyView? = nil

    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.mediaServices) private var services
    @State private var failedURL: String?
    @State private var reported = ReportedURL()

    init(
        spec: ImageSpec,
        tintColor: Color? = nil,
        onSuccess: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil,
        errorContent: AnyView? = nil
    ) {
        DigiaImagePipeline.configureIfNeeded()
        self.spec = spec
        self.tintColor = tintColor
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.errorContent = errorContent
    }

    var body: some View {
        if let url = mediaUsableURL(spec.url) {
            if let cached = Self.memoryCachedPicture(for: url) {
                // Already decoded in memory: drawn from the first body evaluation. WebImage would
                // complete this load inside the view update, where SwiftUI drops its invalidation
                // and the picture never appears.
                fitted(Image(uiImage: cached))
                    .task(id: spec.url) { reportSuccess() }
            } else {
                WebImage(url: url, options: [.retryFailed, .scaleDownLargeImages]) { image in
                    fitted(image)
                } placeholder: {
                    still(failed: failedURL == spec.url)
                }
                .onSuccess { _, _, _ in
                    reportSuccess()
                }
                .onFailure { error in
                    failedURL = spec.url
                    // Only a cause the author can fix is health: no cause (network, timeout, 5xx)
                    // reports nothing.
                    if let cause = mediaFailureCause(imageError: error) {
                        services.reportHealth(campaignKey, .image, cause)
                    }
                    onFailure?()
                }
            }
        } else {
            still(failed: true)
                .task(id: spec.url) {
                    services.reportHealth(campaignKey, .image, "invalid_url")
                    onFailure?()
                }
        }
    }

    /// The success callback, once per URL however the picture arrived.
    private func reportSuccess() {
        guard reported.url != spec.url else { return }
        reported.url = spec.url
        onSuccess?()
    }

    /// The picture when it is a plain bitmap already in the memory cache, under the key the
    /// downloader uses. Animated and vector pictures stay with WebImage, which plays and rasterises
    /// them.
    private static func memoryCachedPicture(for url: URL) -> UIImage? {
        let key = SDWebImageManager.shared.cacheKey(for: url)
        guard let image = SDImageCache.shared.imageFromMemoryCache(forKey: key),
            !image.sd_isAnimated, !image.sd_isVector
        else { return nil }
        return image
    }

    /// What shows until the picture draws, and after a failure.
    @ViewBuilder
    private func still(failed: Bool) -> some View {
        ZStack {
            MediaStill(spec: .image(spec))
            if failed, let errorContent {
                errorContent
            }
        }
    }

    @ViewBuilder
    private func fitted(_ image: Image) -> some View {
        if let tintColor {
            if let mode = spec.fit.contentMode {
                image
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(tintColor)
                    .aspectRatio(contentMode: mode)
            } else {
                image
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(tintColor)
            }
        } else if let mode = spec.fit.contentMode {
            image
                .resizable()
                .aspectRatio(contentMode: mode)
        } else {
            image.resizable()
        }
    }
}

/// The URL whose success was reported. A class so recording it never invalidates the view.
private final class ReportedURL {
    var url: String?
}
