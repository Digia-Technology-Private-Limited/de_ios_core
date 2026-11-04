import Foundation
import DigiaMediaCache
import UIKit

internal import SDWebImageSwiftUI

/// The real prefetch every surface warms through (T12, D6): video byte ranges through the
/// shared range cache (the same store `MediaVideo` reads through, so a warmed range is a
/// cache hit at render), images through the shared SDWebImage cache (the same loader
/// `MediaImage` renders through), Lottie through Lottie's own composition fetch. Callers
/// never touch either store directly, so warming both stays a prefetch detail.
///
/// Mirrors Android's `MediaPrefetch` object. Intended differences: iOS vends `UIImage?`
/// (the floater draws the warmed image instead of refetching) where Android answers `Bool`;
/// the store is injected (defaulting to the process-wide shared store) where Android passes
/// it per call; the campaign key rides the value (set by the warming surface) because the
/// frozen protocol methods take no key.
///
/// Never throws: a blank or still-templated (`{{ }}`) URL warms nothing and answers
/// nil/false/0; a failure is reported through health (unless there is no campaign to blame it
/// on) and answers nil/false/0 — the caller degrades to its still. `file://` images decode
/// from disk (they draw directly, never cached); `file://` video warms nothing (it plays
/// directly, never cached — the same scheme-routing `MediaVideo` uses). Cancelling the
/// caller cancels the in-flight fetch.
struct DefaultMediaPrefetch: MediaPrefetch {
    /// The campaign a warm failure is blamed on. Nil drops the health event (there is
    /// nothing to blame), matching what `reportMediaLoadFailed` already does for a nil key.
    var campaignKey: String?
    /// The range cache video warms land in. Production leaves nil for the process-wide
    /// shared store; tests inject a store backed by a fake fetch client.
    var store: MediaRangeCacheStore?
    /// Ambient services a surface hands down (D17). When set, the store and the
    /// health hook come from here; when nil the two fields above behave exactly
    /// as before. Non-view drivers receive their services directly instead.
    var services: MediaServices? = nil

    init(
        campaignKey: String? = nil,
        store: MediaRangeCacheStore? = nil,
        services: MediaServices? = nil
    ) {
        self.campaignKey = campaignKey
        self.store = store
        self.services = services
    }

    func warmImage(_ url: String) async -> UIImage? {
        guard let parsed = mediaUsableURL(url) else { return nil }
        // Local files draw directly, never cached: decode off the caller (I/O must stay
        // off main) and hand the image back, so floaters still reveal only when loaded.
        if parsed.isFileURL {
            return await Task.detached {
                UIImage(contentsOfFile: parsed.path)
            }.value
        }
        DigiaImagePipeline.configureIfNeeded()
        let gate = ImageLoadGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.begin(
                    makeOperation: { finish in
                        // The shared cache (the same one `MediaImage` renders through, so a
                        // warmed image is a cache hit at render), but loaded through the
                        // loaders manager: custom transports first, the real downloader
                        // otherwise. `SDWebImageManager.shared` cannot be used — it points
                        // at the bare downloader, bypassing appended loaders entirely.
                        Self.warmingManager.loadImage(
                            with: parsed, options: [], context: nil, progress: nil
                        ) { image, _, error, _, _, _ in
                            if let image {
                                finish(image)
                            } else {
                                if let error {
                                    self.report(
                                        .image,
                                        cause: mediaFailureCause(imageError: error) ?? "network")
                                }
                                finish(nil)
                            }
                        }
                    },
                    continuation: continuation
                )
                if Task.isCancelled { gate.cancel() }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    func enqueueImage(_ url: String) {
        guard let parsed = mediaUsableURL(url), !parsed.isFileURL else { return }
        DigiaImagePipeline.configureIfNeeded()
        SDWebImagePrefetcher.shared.prefetchURLs([parsed])
    }

    func warmVideoBytes(url: String, lengthBytes: Int) async -> Int {
        guard let parsed = mediaUsableURL(url), !parsed.isFileURL, lengthBytes > 0 else { return 0 }
        do {
            try await storeOrShared.warm(url: parsed, offset: 0, length: lengthBytes)
        } catch is CancellationError {
            return 0
        } catch {
            report(.video, cause: "network")
            return 0
        }
        if Task.isCancelled { return 0 }
        if let total = await storeOrShared.contentInfo(for: parsed)?.contentLength,
            total >= 0
        {
            return Int(min(Int64(lengthBytes), total))
        }
        return lengthBytes
    }

    func warmWholeVideo(url: String) async -> Int {
        guard let parsed = mediaUsableURL(url), !parsed.isFileURL else { return 0 }
        do {
            try await storeOrShared.warm(url: parsed, offset: 0, length: nil)
        } catch is CancellationError {
            return 0
        } catch {
            report(.video, cause: "network")
            return 0
        }
        if Task.isCancelled { return 0 }
        if let total = await storeOrShared.contentInfo(for: parsed)?.contentLength,
            total >= 0
        {
            return Int(total)
        }
        return 0
    }

    func warmLottie(_ url: String) async -> Bool {
        guard let parsed = mediaUsableURL(url) else { return false }
        let loaded = await loadLottieSource(parsed)
        if Task.isCancelled { return false }
        if loaded.source != nil { return true }
        report(.lottie, cause: loaded.failureCause ?? "network")
        return false
    }

    private var storeOrShared: MediaRangeCacheStore {
        services?.store() ?? store ?? MediaRangeCacheStore.shared()
    }

    private func report(_ kind: HealthMediaKind, cause: String) {
        if let services {
            services.reportHealth(campaignKey, kind, cause)
        } else {
            reportMediaLoadFailed(kind, cause: cause, campaignKey: campaignKey)
        }
    }

    /// The manager image warms go through: the shared cache, loaded through the shared
    /// loaders manager (custom transports first, the real downloader otherwise).
    /// `nonisolated(unsafe)` like `SharedMediaResourceLoader.shared`: SDWebImage's
    /// manager is main-safe and internally locked, but not marked `Sendable`.
    nonisolated(unsafe) private static let warmingManager = SDWebImageManager(
        cache: SDImageCache.shared, loader: SDImageLoadersManager.shared)
}

/// The one-shot bridge between an SDWebImage load and Swift concurrency: the completion
/// resumes the continuation exactly once, and a cancelled caller resumes it with nil while
/// cancelling the fetch. The completion runs on the main queue and cancellation on an
/// arbitrary one, so the first-to-finish wins under a lock.
private final class ImageLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (any SDWebImageOperation)?
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var finished = false

    /// Starts `makeOperation`, handing it the finish-once closure. The continuation is
    /// captured so a later `cancel` can resume it.
    func begin(
        makeOperation: (@escaping @Sendable (UIImage?) -> Void) -> (any SDWebImageOperation)?,
        continuation: CheckedContinuation<UIImage?, Never>
    ) {
        let finish: @Sendable (UIImage?) -> Void = { [weak self] image in
            self?.finish(image)
        }
        lock.withLock {
            self.continuation = continuation
            if finished {
                continuation.resume(returning: nil)
                return
            }
            operation = makeOperation(finish)
        }
    }

    func cancel() {
        lock.withLock {
            operation?.cancel()
            operation = nil
            guard !finished else { return }
            finished = true
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }

    private func finish(_ image: UIImage?) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            operation = nil
            continuation?.resume(returning: image)
            continuation = nil
        }
    }
}
