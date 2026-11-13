import Foundation
import SDWebImage
import Testing

@testable import DigiaEngage

/// A cache key filter that gives every lookup a key of its own. Built outside the main actor: the
/// image library calls it from its decode queue.
private func unstableCacheKeyFilter() -> SDWebImageCacheKeyFilter {
    SDWebImageCacheKeyFilter { _ in UUID().uuidString }
}

extension RenderedUITests {
/// What the floater reports to health, read from the SDK's real sink with the network faked
/// underneath: the Lottie warm-up and the drop report have no view to read the environment from,
/// and the window's own media reads the campaign key from the floater's view tree.
@Suite("Media floater: health reports", .serialized,
       .tags(.integration, .media, .floater),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct MediaFloaterServicesTests {

    // Fails if: media_load_health.swift `mediaFailureCause(httpStatus:)` `case (400..<500)?: "http_4xx"`
    // is deleted: the report then carries no cause and is never sent.
    @Test("a floater's Lottie the server 404s is dropped and reported as http_4xx for its campaign")
    func lottieWarmUpReportsTheServersStatus() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("payday.lottie")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let json = try floaterFixture(
            "pip/pip_media_lottie", setting: [(["media", "url"], target.absoluteString)])
        let sdk = try await SdkHarness.start(json)
        defer { sdk.tearDown() }

        _ = try sdk.deliverFloater(keyOf(json))
        try await sdk.waitUntil("the floater is dropped", timeout: 5) { sdk.pip.state == nil }

        #expect(MediaOrigin.requests(for: target).count == 1)
        let failures = sdk.records(keyOf(json), reason: TimelineReason.mediaLoadFailed)
        #expect(failures.count == 1)
        #expect(failures.first?.extras["cause"] == "http_4xx")
        #expect(failures.first?.extras["media_kind"] == "lottie")
    }

    // Fails if: floater_overlay_view.swift `FloaterOverlayView` loses its
    // `.environment(\.digiaCampaignKey, state.payload.campaignKey)` on `FloaterSessionView`: the
    // window's image then fails with no campaign key and `reportMediaLoadFailed` drops the report.
    @Test("a floater image that fails once the window is up is reported with the floater's campaign key")
    func windowImageFailureCarriesTheCampaignKey() async throws {
        MediaOrigin.install()
        // Every lookup misses the cache, so the window fetches the picture again after the preload
        // that revealed it, and that second fetch is the one the server refuses.
        SDWebImageManager.shared.cacheKeyFilter = unstableCacheKeyFilter()
        defer {
            SDWebImageManager.shared.cacheKeyFilter = nil
            MediaOrigin.end()
        }
        let target = MediaOrigin.url("pip.png")
        MediaOrigin.queue([.status(200, solidPNG(.red))], for: target)
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let json = try floaterFixture(
            "degradation/degrade_pip_media_404", setting: [(["media", "url"], target.absoluteString)])
        let sdk = try await SdkHarness.start(json)
        defer { sdk.tearDown() }

        _ = try sdk.deliverFloater(keyOf(json))
        try await sdk.waitUntil("the window fetches its picture again", timeout: 10) {
            MediaOrigin.requests(for: target).count >= 2
        }
        try await sdk.settle(0.5)

        let failures = sdk.records(keyOf(json), reason: TimelineReason.mediaLoadFailed)
        // Every lookup misses the cache here, so a redraw fetches again and reports again: how many
        // times is the filter's, that there is a report for this campaign at all is the test.
        #expect(!failures.isEmpty)
        #expect(failures.allSatisfy { $0.extras["cause"] == "http_4xx" && $0.extras["media_kind"] == "image" })
    }
}
}
