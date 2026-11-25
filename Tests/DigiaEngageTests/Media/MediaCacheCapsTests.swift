import Foundation
import Testing

@testable import DigiaEngage

/// The media disk caps at the pipeline: a resolved `SdkConfig` moves the owned image cache
/// and the Lottie download session, and the defaults leave both at 100 MiB.
///
/// Every test here is synchronous and restores the 100 MiB defaults before returning, so the
/// process-wide cache and session never sit on a custom cap while the suites that assume the
/// defaults (`MediaImageDecisionTests`, `LottieHTTPCacheTests`) run alongside this one. The
/// custom Lottie cap is 96 MiB: high enough that a 4 MiB response still fits the URLCache ~5%
/// per-response rule even under direct overlap. How `initialize()` feeds the cached and then
/// the fetched config into `applySdkConfig` is covered by `SDKInstanceSdkConfigTests`.
@MainActor
@Suite("Media disk caps", .serialized, .tags(.media, .unit))
struct MediaCacheCapsTests {
    private static let mib = 1024 * 1024

    private func restoreDefaults() {
        DigiaImagePipeline.imageCache.config.maxDiskSize = UInt(SdkConfig.defaultMediaDiskCacheBytes)
        setLottieDiskCacheBytes(SdkConfig.defaultMediaDiskCacheBytes)
    }

    @Test("the defaults are 100 MiB on both caches")
    func defaultsAre100MiB() {
        #expect(SdkConfig.defaultMediaDiskCacheBytes == 100 * Self.mib)
        #expect(UInt(SdkConfig.defaultMediaDiskCacheBytes) == DigiaImagePipeline.maxDiskSize)
        #expect(DigiaImagePipeline.imageCache.config.maxDiskSize == UInt(100 * Self.mib))
        #expect(lottieDownloadSession().configuration.urlCache?.diskCapacity == 100 * Self.mib)
    }

    @Test("the image cache honors a resolved custom cap, keeping the 7-day age")
    func imageHonorsResolvedCap() {
        defer { restoreDefaults() }
        let resolved = SdkConfig.resolve(fetched: ["media": ["imageDiskCacheBytes": 64 * Self.mib]])

        // The image line of `applySdkConfig`.
        DigiaImagePipeline.imageCache.config.maxDiskSize = UInt(resolved.imageDiskCacheBytes)

        #expect(DigiaImagePipeline.imageCache.config.maxDiskSize == UInt(64 * Self.mib))
        #expect(DigiaImagePipeline.imageCache.config.maxDiskAge == 7 * 24 * 3600)
    }

    @Test("the Lottie session honors a resolved custom cap, keeping its shape")
    func lottieHonorsResolvedCap() {
        defer { restoreDefaults() }
        let resolved = SdkConfig.resolve(fetched: ["media": ["lottieDiskCacheBytes": 96 * Self.mib]])

        // The Lottie line of `applySdkConfig`.
        setLottieDiskCacheBytes(resolved.lottieDiskCacheBytes)

        let session = lottieDownloadSession()
        #expect(session.configuration.urlCache?.diskCapacity == 96 * Self.mib)
        #expect(session.configuration.urlCache?.memoryCapacity == 0)
        #expect(session.configuration.requestCachePolicy == .useProtocolCachePolicy)
    }

    @Test("the Lottie session is rebuilt only when its cap changes")
    func sessionRebuiltOnlyOnChange() {
        defer { restoreDefaults() }
        setLottieDiskCacheBytes(SdkConfig.defaultMediaDiskCacheBytes)

        let first = lottieDownloadSession()
        setLottieDiskCacheBytes(SdkConfig.defaultMediaDiskCacheBytes)
        #expect(lottieDownloadSession() === first)

        setLottieDiskCacheBytes(96 * Self.mib)
        #expect(lottieDownloadSession() !== first)
    }
}
