import SwiftUI
import UIKit
internal import SDWebImageSVGCoder
internal import SDWebImageSwiftUI

enum DigiaImagePipeline {
    private static let configureOnce: Void = {
        SDImageCodersManager.shared.addCoder(SDImageSVGCoder.shared)
    }()

    static func configureIfNeeded() {
        _ = configureOnce
    }
}

/// Pre-T6 render body kept byte-identical until W3/W4 move its callers onto
/// `MediaImage` directly (forwarder removed in T17): bare `WebImage` with the
/// caller's placeholder in its slot, so inline stills/thumbnails/banners
/// render exactly as before. `fit: .fill` keeps sizing outside as before.
struct DigiaCachedImageView: View {
    let url: URL
    let tintColor: Color?
    let placeholder: AnyView
    let onSuccess: ((UIImage) -> Void)?
    let onFailure: (() -> Void)?

    @Environment(\.digiaCampaignKey) private var campaignKey

    init(
        url: URL,
        tintColor: Color? = nil,
        placeholder: AnyView = AnyView(Color.clear),
        onSuccess: ((UIImage) -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        DigiaImagePipeline.configureIfNeeded()
        self.url = url
        self.tintColor = tintColor
        self.placeholder = placeholder
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    var body: some View {
        WebImage(url: url, options: [.retryFailed, .scaleDownLargeImages]) { image in
            configuredImage(image)
        } placeholder: {
            placeholder
        }
        .onSuccess { image, _, _ in
            onSuccess?(image)
        }
        .onFailure { error in
            reportMediaLoadFailed(.image, cause: mediaFailureCause(imageError: error), campaignKey: campaignKey)
            onFailure?()
        }
    }

    @ViewBuilder
    private func configuredImage(_ image: Image) -> some View {
        if let tintColor {
            image
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(tintColor)
        } else {
            image.resizable()
        }
    }
}
