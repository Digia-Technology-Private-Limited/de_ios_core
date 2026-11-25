import SwiftUI

/// Tiny decode cache so recomposition doesn't re-run the inverse DCT — hashes
/// are stable per campaign payload, so this stays small.
enum BlurHashCache {
    /// Size a hash is decoded at; the upscale to the image box is the blur.
    static let decodeSize = 32

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
