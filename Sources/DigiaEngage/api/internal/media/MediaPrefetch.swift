import Foundation

internal import DigiaMediaCache
internal import SDWebImage

/// What a warm fetches into its cache.
enum MediaPrefetchKind: Sendable {
    case image
    case lottie
    case video
}

/// Warms media into the caches the wrappers read, so a later render reuses the bytes: the first
/// `bytes` of a video into the range cache, the whole file of an image (SDWebImage's cache) or a
/// Lottie (Lottie's cache). Something already cached makes no request. Internal: there is no
/// app-start policy, callers (the story plan) decide what to warm.
///
/// A failed warm is silent: the render that follows reports its own health.
enum MediaPrefetch {
    /// The first bytes of a video a warm fetches when the caller doesn't say.
    static let defaultVideoBytes = 512 * 1_024

    static func warm(
        _ url: String, kind: MediaPrefetchKind, bytes: Int? = nil, services: MediaServices = .current
    ) async {
        guard let parsed = mediaUsableURL(url) else { return }
        switch kind {
        case .video:
            // HLS and file URLs have nothing to warm in the range cache.
            guard MediaResourceLoader.isCacheable(parsed) else { return }
            try? await services.videoStore.warm(url: parsed, offset: 0, length: bytes ?? defaultVideoBytes)
        case .image:
            DigiaImagePipeline.configureIfNeeded()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SDWebImageManager.shared.loadImage(
                    with: parsed, options: [.retryFailed, .scaleDownLargeImages], progress: nil
                ) { _, _, _, _, _, _ in
                    continuation.resume()
                }
            }
        case .lottie:
            _ = await services.loadLottie(parsed)
        }
    }
}
