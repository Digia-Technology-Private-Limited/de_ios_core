import SwiftUI
import UIKit
import SDWebImageSwiftUI
import SDWebImageSVGCoder

enum DigiaImagePipeline {
    private static let configureOnce: Void = {
        SDImageCodersManager.shared.addCoder(SDImageSVGCoder.shared)
    }()

    static func configureIfNeeded() {
        _ = configureOnce
    }
}

struct DigiaCachedImageView: View {
    let url: URL
    let tintColor: Color?
    let placeholder: AnyView
    let onSuccess: ((UIImage) -> Void)?
    let onFailure: (() -> Void)?

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
            .onFailure { _ in
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
