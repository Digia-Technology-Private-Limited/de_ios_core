internal import SDWebImageSwiftUI
internal import SDWebImageSVGCoder

/// The `User-Agent` every Engage image fetch sends, so CDN logs can tell SDK traffic apart.
let DIGIA_IMAGE_USER_AGENT = "DigiaEngage/1.0 (iOS)"

enum DigiaImagePipeline {
    private static let configureOnce: Void = {
        SDImageCodersManager.shared.addCoder(SDImageSVGCoder.shared)
    }()

    static func configureIfNeeded() {
        _ = configureOnce
    }
}
