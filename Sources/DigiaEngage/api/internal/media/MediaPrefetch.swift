import Foundation

internal import DigiaVideoEngine
internal import SDWebImage

/// Warms media into the caches the wrappers read, so a later render reuses the bytes: the first
/// `bytes` of a video into the range cache, the whole file of an image (SDWebImage's cache) or a
/// Lottie (Lottie's cache). Something already cached makes no request. Internal: there is no
/// app-start policy, callers (the story plan) decide what to warm.
///
/// A failed warm is silent: the render that follows reports its own health. `warm` answers the
/// bytes of a video it delivered: 0 for a warm that was cancelled or failed, and for anything that
/// is not a cacheable video. A caller measuring throughput counts only a positive answer.
enum MediaPrefetch {
    @discardableResult
    static func warm(
        _ url: String, kind: MediaPrefetchKind, bytes: Int? = nil, services: MediaServices = .current
    ) async -> Int {
        guard let parsed = mediaUsableURL(url) else { return 0 }
        switch kind {
        case .video:
            return await warmVideoBytes(url, bytes: bytes, store: services.videoStore)
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
        return 0
    }
}
