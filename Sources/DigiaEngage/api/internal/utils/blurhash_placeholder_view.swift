import SwiftUI

/// Renders the decoded BlurHash for an `ImagePlaceholder` filling the available
/// space, or nothing when there is no hash. For use in an image view's
/// `placeholder:` slot (WebImage / AsyncImage).
///
/// Loader/shimmer types are recognised but not yet rendered — the dashboard
/// only authors `blurhash` today.
struct BlurHashPlaceholderView: View {
    let placeholder: ImagePlaceholder?
    /// `nil` stretches the decoded image to the proposed frame.
    let contentMode: ContentMode?

    init(placeholder: ImagePlaceholder?, contentMode: ContentMode? = .fill) {
        self.placeholder = placeholder
        self.contentMode = contentMode
    }

    /// Size the hash is decoded at; the upscale to the image box is the blur.
    private static let decodeSize = 32

    private var decoded: UIImage? {
        guard let placeholder,
              placeholder.type == .blurhash,
              let hash = placeholder.blurHash
        else { return nil }
        return BlurHashCache.image(for: hash, size: Self.decodeSize)
    }

    var body: some View {
        if let image = decoded {
            if let contentMode {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(uiImage: image)
                    .resizable()
            }
        }
    }
}

/// Tiny decode cache so recomposition doesn't re-run the inverse DCT — hashes
/// are stable per campaign payload, so this stays small.
private enum BlurHashCache {
    // NSCache is documented thread-safe, so unsynchronised shared access is fine.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func image(for hash: String, size: Int) -> UIImage? {
        let key = hash as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let decoded = BlurHashDecoder.decode(hash, width: size, height: size) else {
            return nil
        }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}
