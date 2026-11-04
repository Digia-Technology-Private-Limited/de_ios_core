import SwiftUI
import UIKit

internal import SDWebImageSwiftUI

/// The one image wrapper every surface renders through (D1): SDWebImage via the shared cache
/// (D6 — GIF/SVG decoding unchanged from `DigiaCachedImageView`), with the authored BlurHash as
/// the bottom layer while loading AND on error (D5), so the box below is never empty.
///
/// A load failure — network ones included — is reported through the media health hook with a
/// non-nil cause (D5), and the still stays regardless. A spinner joins only after
/// `spinnerDelaySeconds` with nothing better to show (US9), so short waits feel calm.
///
/// Never throws from the render path: a blank, templated or otherwise unusable URL simply shows
/// the still without fetching and without reporting.
struct MediaImage: View {
    /// How long a still-less load stays blank before the spinner joins it (US9). Named so the
    /// trailing tests can pin the exact production line (meaningful-tests rule 2).
    static let spinnerDelaySeconds: TimeInterval = 0.4

    let spec: ImageSpec
    var tintColor: Color? = nil
    /// An already-decoded image (e.g. handed back by `MediaPrefetch.warmImage`): drawn instead
    /// of fetching, so a surface that reveals only when loaded never flashes (US50).
    var preloaded: UIImage? = nil
    var onSuccess: ((UIImage) -> Void)? = nil
    /// The fetch failed. The argument is the same non-nil cause sent to health.
    var onFailure: ((String) -> Void)? = nil

    @Environment(\.mediaServices) private var services
    @Environment(\.digiaCampaignKey) private var campaignKey
    @State private var finished = false
    @State private var showSpinner = false

    private let blurStill: UIImage?

    init(
        spec: ImageSpec,
        tintColor: Color? = nil,
        preloaded: UIImage? = nil,
        onSuccess: ((UIImage) -> Void)? = nil,
        onFailure: ((String) -> Void)? = nil
    ) {
        DigiaImagePipeline.configureIfNeeded()
        self.spec = spec
        self.tintColor = tintColor
        self.preloaded = preloaded
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.blurStill = spec.blurHash.flatMap { BlurHashDecoder.decode($0, width: 32, height: 32) }
    }

    /// The US9 rule: the spinner appears only after `spinnerDelaySeconds` of waiting AND only
    /// when no BlurHash still covers the box. Pure so the trailing boundary tests pin it.
    static func showsSpinner(hasBlurStill: Bool, waited: TimeInterval) -> Bool {
        !hasBlurStill && waited >= spinnerDelaySeconds
    }

    var body: some View {
        ZStack {
            if let blurStill {
                if let mode = spec.fit.contentMode {
                    Image(uiImage: blurStill)
                        .resizable()
                        .aspectRatio(contentMode: mode)
                } else {
                    Image(uiImage: blurStill)
                        .resizable()
                }
            } else if showSpinner, !finished {
                ProgressView()
            }
            if let preloaded {
                fitted(Image(uiImage: preloaded))
                    .task {
                        finished = true
                        onSuccess?(preloaded)
                    }
            } else if let url = mediaUsableURL(spec.url) {
                WebImage(url: url, options: [.retryFailed, .scaleDownLargeImages]) { image in
                    fitted(image)
                } placeholder: {
                    Color.clear
                }
                .onSuccess { image, _, _ in
                    finished = true
                    showSpinner = false
                    onSuccess?(image)
                }
                .onFailure { error in
                    finished = true
                    showSpinner = false
                    // D5: every failure, network ones included, reports with a non-nil cause.
                    // The shared mapper returns nil for transport failures (no status to blame),
                    // which are delivery faults, not silent holes, so they report as "network".
                    let cause = mediaFailureCause(imageError: error) ?? "network"
                    services.reportHealth(campaignKey, .image, cause)
                    onFailure?(cause)
                }
            }
        }
        .task(id: spec.url) {
            // The spinner arm: cancelled on disappear or URL change, and disarmed by `finished`.
            // A still-less load that resolves in time never flashes it.
            try? await Task.sleep(nanoseconds: UInt64(Self.spinnerDelaySeconds * 1_000_000_000))
            if !Task.isCancelled {
                showSpinner = MediaImage.showsSpinner(
                    hasBlurStill: blurStill != nil, waited: Self.spinnerDelaySeconds)
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
