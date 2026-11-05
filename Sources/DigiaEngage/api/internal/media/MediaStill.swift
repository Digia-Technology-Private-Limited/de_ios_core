import SwiftUI
import UIKit

/// The authored BlurHash drawn as a still, fitted like the picture it stands in for. It is
/// decoded once per hash (`BlurHashCache`), not on every render. Draws nothing when there is
/// no hash.
struct MediaStill: View {
    var fit: MediaFit = .cover
    var blurHash: String? = nil

    var body: some View {
        if let hash = blurHash,
            let image = BlurHashCache.image(for: hash, size: BlurHashPlaceholderView.decodeSize)
        {
            if let mode = fit.contentMode {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: mode)
            } else {
                Image(uiImage: image)
                    .resizable()
            }
        }
    }
}
