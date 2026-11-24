internal import SDWebImageSwiftUI
internal import SDWebImageSVGCoder

/// The `User-Agent` every Engage image fetch sends, so CDN logs can tell SDK traffic apart.
let DIGIA_IMAGE_USER_AGENT = "DigiaEngage/1.0 (iOS)"

enum DigiaImagePipeline {
    /// The disk namespace every Engage picture is cached under. Separate from the host app's
    /// shared SDWebImage cache (namespace `default`) and from the Lottie HTTP disk cache
    /// (`Caches/DigiaEngageLottie`), so the SDK's pictures never evict, and are never evicted
    /// by, anything outside the SDK.
    static let diskCacheNamespace = "DigiaEngageImages"

    /// The disk cap for Engage pictures: 100 MiB, kept for a week. SDWebImage's shared cache
    /// defaults to unbounded disk (`maxDiskSize == 0`); this owned cache is bounded instead.
    /// The starting value: `SDKInstance` moves the live `imageCache.config.maxDiskSize` to the
    /// server-driven `SdkConfig.imageDiskCacheBytes` whenever a config applies. `maxDiskAge`
    /// is not configured and stays a week.
    static let maxDiskSize: UInt = 100 * 1024 * 1024
    static let maxDiskAge: TimeInterval = 7 * 24 * 3600

    /// The one cache every Engage picture reads and writes: `MediaImage` (via `imageManager`),
    /// the floater's preload and the guide's prefetch. Nothing outside the SDK touches it.
    /// Thread-safe by the image library's design (its own I/O queue and locks), hence
    /// `nonisolated(unsafe)`, as with the SDK's other process-wide statics.
    nonisolated(unsafe) static let imageCache: SDImageCache = {
        let config = SDImageCacheConfig()
        config.maxDiskSize = maxDiskSize
        config.maxDiskAge = maxDiskAge
        return SDImageCache(
            namespace: diskCacheNamespace, diskCacheDirectory: nil, config: config)
    }()

    /// The one loader every Engage picture goes through, fronting the owned cache. It shares
    /// the downloader with the host app (so test fakes on it still apply) but keeps its own
    /// failed-URL list and cache-key filter, so host traffic cannot poison SDK loads.
    nonisolated(unsafe) static let imageManager: SDWebImageManager = {
        SDWebImageManager(cache: imageCache, loader: SDWebImageDownloader.shared)
    }()

    /// The prefetcher the guide warms the next step's picture with, bound to the owned
    /// manager so the prefetched bytes land in the entry `MediaImage` reads.
    nonisolated(unsafe) static let imagePrefetcher: SDWebImagePrefetcher = {
        SDWebImagePrefetcher(imageManager: imageManager)
    }()

    private static let configureOnce: Void = {
        SDImageCodersManager.shared.addCoder(SDImageSVGCoder.shared)
    }()

    static func configureIfNeeded() {
        _ = configureOnce
    }
}
