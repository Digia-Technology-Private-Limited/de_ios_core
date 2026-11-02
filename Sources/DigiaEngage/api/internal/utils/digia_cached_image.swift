import SwiftUI
import UIKit
internal import SDWebImageSVGCoder

enum DigiaImagePipeline {
    private static let configureOnce: Void = {
        SDImageCodersManager.shared.addCoder(SDImageSVGCoder.shared)
    }()

    static func configureIfNeeded() {
        _ = configureOnce
    }
}

/// Thin forwarder to `MediaImage` until W3/W4 move its callers (T6): same interface, the
/// caller's placeholder stays the bottom layer, `fit: .fill` keeps sizing outside as before.
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
        self.url = url
        self.tintColor = tintColor
        self.placeholder = placeholder
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    var body: some View {
        ZStack {
            placeholder
            MediaImage(
                spec: MediaSpec(url: url.absoluteString, fit: .fill),
                tintColor: tintColor,
                onSuccess: onSuccess,
                onFailure: { _ in onFailure?() }
            )
        }
    }
}
