import SwiftUI
import UIKit

internal import SDWebImageSwiftUI

/// The one image wrapper the non-story surfaces render through: SDWebImage via the shared cache
/// and downloader (GIF and SVG decoding as before), with the authored BlurHash drawn through
/// the image library's own loading and error slots, so it is gone once the picture draws (a
/// transparent or letterboxed picture never shows a stale blur) and the box is never empty
/// before that. There is no spinner.
///
/// When the load fails, and when the URL is unusable (blank, an unresolved `{{variable}}`, no
/// scheme), the box shows the error placeholder ("Image failed") and no BlurHash: `errorContent`
/// replaces the placeholder, for surfaces that draw their own failure look. The BlurHash is for
/// loading only. The tint applies to the picture only.
///
/// `focalX` and `focalY` (0-1) say where the picture sits in its box: the overflow of a cropped
/// picture, or the free space around a letterboxed one, is split so that the picture's offset is
/// (box - picture) x focal on each axis, continuously (0.5 is centred). `zoom` scales the drawn
/// content, the picture and its still alike, around the point (focalX, focalY) of the box: the
/// picture is fitted and cropped to the box first, then that box is scaled and clipped again, so
/// below 1 the page shows around a smaller cropped picture. All three are clamped
/// (focal 0-1, zoom 0.1-10, anything non-finite is the default), and at their defaults (0.5, 0.5,
/// 1) the picture is drawn exactly as without them. The failure look is not zoomed or placed.
///
/// Health is reported once per failure, for the campaign in the environment: `invalid_url` for
/// an unusable URL, `http_4xx`, `decode`. A network failure, a timeout or a 5xx reports nothing.
///
/// Never throws from the render path: an unusable URL shows the error placeholder without fetching.
struct MediaImage: View {
    /// The options every load of a wrapper picture uses. A preload (the floater's) passes the same
    /// set, so its picture lands in the cache entry this wrapper reads instead of being fetched again.
    static let loadOptions: SDWebImageOptions = [.retryFailed, .scaleDownLargeImages]

    let url: String
    var fit: MediaFit = .cover
    var blurHash: String? = nil
    var tintColor: Color? = nil
    var focalX: CGFloat = 0.5
    var focalY: CGFloat = 0.5
    var zoom: CGFloat = 1
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
        url: String,
        fit: MediaFit = .cover,
        blurHash: String? = nil,
        tintColor: Color? = nil,
        focalX: CGFloat = 0.5,
        focalY: CGFloat = 0.5,
        zoom: CGFloat = 1,
        onSuccess: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil,
        errorContent: AnyView? = nil
    ) {
        DigiaImagePipeline.configureIfNeeded()
        self.url = url
        self.fit = fit
        self.blurHash = blurHash
        self.tintColor = tintColor
        self.focalX = focalX
        self.focalY = focalY
        self.zoom = zoom
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.errorContent = errorContent
    }

    var body: some View {
        if let target = mediaUsableURL(url) {
            if let cached = Self.memoryCachedPicture(for: target) {
                // Already decoded in memory: drawn from the first body evaluation. WebImage would
                // complete this load inside the view update, where SwiftUI drops its invalidation
                // and the picture never appears.
                placed(fitted(Image(uiImage: cached)))
                    .task(id: url) { reportSuccess() }
            } else {
                WebImage(url: target, options: Self.loadOptions) { image in
                    placed(fitted(image))
                } placeholder: {
                    still(failed: failedURL == url)
                }
                .onSuccess { _, _, _ in
                    reportSuccess()
                }
                .onFailure { error in
                    failedURL = url
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
                .task(id: url) {
                    services.reportHealth(campaignKey, .image, "invalid_url")
                    onFailure?()
                }
        }
    }

    /// The success callback, once per URL however the picture arrived.
    private func reportSuccess() {
        guard reported.url != url else { return }
        reported.url = url
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

    /// What shows until the picture draws (the still), and after a failure (the error look, with no
    /// still behind it).
    /// The wrapper ZStack stays the same view in both states: the image library re-runs its load when
    /// the placeholder slot's root view is replaced, which would fetch a failed URL again.
    @ViewBuilder
    private func still(failed: Bool) -> some View {
        ZStack {
            if failed {
                errorContent ?? AnyView(MediaErrorPlaceholder(label: "Image failed"))
            } else {
                placed(MediaStill(fit: fit, blurHash: blurHash))
            }
        }
    }

    private static func clamped(_ value: CGFloat, _ range: ClosedRange<CGFloat>, default fallback: CGFloat)
        -> CGFloat
    {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    /// `content` placed by the focal point and zoomed, in the box it is given. Untouched at the
    /// defaults, so existing surfaces keep their layout.
    @ViewBuilder
    private func placed<Content: View>(_ content: Content) -> some View {
        let fx = Self.clamped(focalX, 0...1, default: 0.5)
        let fy = Self.clamped(focalY, 0...1, default: 0.5)
        let scale = Self.clamped(zoom, 0.1...10, default: 1)
        if fx == 0.5, fy == 0.5, scale == 1 {
            content
        } else {
            GeometryReader { box in
                // The frame lines the content's leading/top guide up with the box's; the guide
                // sits (picture - box) x focal inside the content, so the content's offset is
                // (box - picture) x focal.
                content
                    .alignmentGuide(.leading) { -(box.size.width - $0.width) * fx }
                    .alignmentGuide(.top) { -(box.size.height - $0.height) * fy }
                    .frame(width: box.size.width, height: box.size.height, alignment: .topLeading)
                    .clipped()
                    .scaleEffect(scale, anchor: UnitPoint(x: fx, y: fy))
                    .clipped()
            }
        }
    }

    @ViewBuilder
    private func fitted(_ image: Image) -> some View {
        if let tintColor {
            if let mode = fit.contentMode {
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
        } else if let mode = fit.contentMode {
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
