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
            WebImage(url: url, options: [.retryFailed, .scaleDownLargeImages]) { image in
                fitted(image)
            } placeholder: {
                still(failed: failedURL == spec.url)
            }
            .onSuccess { _, _, _ in
                onSuccess?()
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
        } else {
            still(failed: true)
                .task(id: spec.url) {
                    services.reportHealth(campaignKey, .image, "invalid_url")
                    onFailure?()
                }
        }
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
