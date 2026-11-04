import Foundation
import SDWebImage
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The wrapper over a fake origin (`MediaOrigin`): `MediaImage` renders through the real SDWebImage
// downloader and cache, and only the HTTP layer is faked, so what is asserted is what the SDK
// ships. Each test below names the one production line whose change fails it; see
// ai_docs/meaningful-tests.md.

extension RenderedUITests {
@MainActor
@Suite("MediaImage wrapper", .serialized, .tags(.media, .component))
struct MediaImageComponentTests {
    private static let blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    private static let campaign = "test-campaign"

    /// The marker `errorContent` draws: a green square in the middle of the box.
    private static let marker = AnyView(Color(red: 0, green: 0.5, blue: 0).frame(width: 40, height: 40))
    private static let green = RGB(r: 0, g: 0.5, b: 0)

    private func mount(
        _ spec: ImageSpec, recorder: HealthRecorder = HealthRecorder(), errorContent: AnyView? = nil
    ) -> UIWindow {
        mountMedia(
            MediaImage(spec: spec, errorContent: errorContent)
                .environment(\.digiaCampaignKey, Self.campaign)
                .environment(\.mediaServices, recorder.services)
                .frame(width: 200, height: 200)
        )
    }

    private func rendered(_ window: UIWindow) -> UIImage {
        ComponentTestHost.renderImage(of: window.rootViewController!.view)
    }

    private func renderedCenter(_ window: UIWindow) -> RGB? {
        centerPixel(of: rendered(window))
    }

    // Fails if the blur is not drawn while the fetch is in flight: the placeholder slot of the
    // WebImage in MediaImage.body. The request log proves the fetch really started (else the
    // still would show vacuously), and the response is held so the load cannot finish early.
    @Test("the authored blurhash shows while the picture is held")
    func blurShowsWhileLoading() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("held.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target, held: true)
        let recorder = HealthRecorder()

        let window = mount(ImageSpec(url: target.absoluteString, blurHash: Self.blurHash), recorder: recorder)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)
        let middle = renderedCenter(window)
        let blur = blurCenter(Self.blurHash)
        #expect(middle != nil && blur != nil)
        #expect(pixelsNearly(middle!, blur!))
        #expect(recorder.all.isEmpty)

        MediaOrigin.release(target)
        let red = RGB(r: 1, g: 0, b: 0)
        #expect(await waitUntilMedia { renderedCenter(window).map { pixelsNearly($0, red) } ?? false })
    }

    // Fails if a 404 leaves a hole instead of the still: the placeholder slot of the WebImage in
    // MediaImage.body. Fails if the label is not drawn over the still: the `errorContent` line in
    // MediaImage.still. Fails if the failure is not attributed to the campaign, kind and cause:
    // the `services.reportHealth(campaignKey, .image, ...)` call in MediaImage.onFailure.
    @Test("a picture the server 404s keeps the still under errorContent and reports one http_4xx for the campaign")
    func notFoundKeepsStillAndReports() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("missing.png")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()

        let window = mount(
            ImageSpec(url: target.absoluteString, blurHash: Self.blurHash), recorder: recorder,
            errorContent: Self.marker)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(recorder.all == [.init(campaignKey: Self.campaign, kind: .image, cause: "http_4xx")])
        expectStillUnderMarker(window)
    }

    // Fails if a 5xx or a transport failure is reported: the `default: nil` of
    // `mediaFailureCause(httpStatus:)` and the nil cause `mediaFailureCause(imageError:)` returns
    // for a non-HTTP error. The still stays either way.
    @Test("a server error or a lost connection reports nothing and keeps the still", arguments: [
        MediaOrigin.Reply.status(503, Data("busy".utf8)),
        MediaOrigin.Reply.fail(.notConnectedToInternet),
    ])
    func serverAndNetworkFailuresReportNothing(reply: MediaOrigin.Reply) async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("flaky.png")
        MediaOrigin.set(reply, for: target)
        let recorder = HealthRecorder()

        let window = mount(
            ImageSpec(url: target.absoluteString, blurHash: Self.blurHash), recorder: recorder,
            errorContent: Self.marker)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.5)
        #expect(recorder.all.isEmpty)
        expectStillUnderMarker(window)
    }

    // Fails if the blur survives behind a loaded picture: the BlurHash is drawn from the WebImage
    // placeholder slot in MediaImage.body, so moving `MediaStill` out of it (a sibling under the
    // WebImage) leaves it showing through the transparent half.
    @Test("the blur is gone once the picture draws, so a transparent area shows what is behind")
    func blurIsGoneAfterSuccess() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("half.png")
        MediaOrigin.set(.status(200, halfTransparentPNG()), for: target, held: true)

        let window = mount(ImageSpec(url: target.absoluteString, blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })

        MediaOrigin.release(target)
        let red = RGB(r: 1, g: 0, b: 0)
        let white = RGB(r: 1, g: 1, b: 1)
        #expect(await waitUntilMedia {
            pixel(of: rendered(window), atX: 0.25, y: 0.5).map { pixelsNearly($0, red) } ?? false
        })
        ComponentTestHost.drainRunLoop(for: 0.3)
        let transparent = pixel(of: rendered(window), atX: 0.75, y: 0.5)
        #expect(transparent != nil && pixelsNearly(transparent!, white, tolerance: 0.02))
    }

    // Fails if a picture already in the SDImageCache memory cache is not drawn on the first render:
    // `MediaImage.memoryCachedPicture` and its branch in MediaImage.body (WebImage alone completes a
    // cache hit inside the view update, and SwiftUI drops the invalidation, so the picture never
    // appears). Fails if the blur stays behind it: the transparent half must show what is behind.
    // The origin is not installed, so the red can only have come from the cache.
    @Test("a picture already in the memory cache draws on the first render, once reported, leaving no blur", arguments: [
        false, true,
    ])
    func cachedPictureDrawsOnFirstRender(withBlurHash: Bool) throws {
        let target = MediaOrigin.url("cached.png")
        let picture = try #require(UIImage(data: halfTransparentPNG()))
        SDImageCache.shared.storeImage(toMemory: picture, forKey: target.absoluteString)
        defer { SDImageCache.shared.removeImageFromMemory(forKey: target.absoluteString) }
        try #require(SDImageCache.shared.imageFromMemoryCache(forKey: target.absoluteString) != nil)

        let successes = SuccessCount()
        let spec = ImageSpec(url: target.absoluteString, blurHash: withBlurHash ? Self.blurHash : nil)
        let window = mountMedia(
            MediaImage(spec: spec, onSuccess: { successes.count += 1 })
                .environment(\.digiaCampaignKey, Self.campaign)
                .environment(\.mediaServices, HealthRecorder().services)
                .frame(width: 200, height: 200)
        )
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.5)

        let red = RGB(r: 1, g: 0, b: 0)
        let white = RGB(r: 1, g: 1, b: 1)
        let drawn = rendered(window)
        let left = pixel(of: drawn, atX: 0.25, y: 0.5)
        let right = pixel(of: drawn, atX: 0.75, y: 0.5)
        #expect(left != nil && pixelsNearly(left!, red))
        #expect(right != nil && pixelsNearly(right!, white, tolerance: 0.02))
        #expect(successes.count == 1)
    }

    // Fails if an unusable URL reaches the downloader or goes unreported: the `mediaUsableURL`
    // guard in MediaImage.body. Fails if the label is dropped for it: `still(failed: true)`.
    @Test("a blank, unresolved or schemeless url never fetches, keeps the still under errorContent, and reports invalid_url once", arguments: [
        "",
        "   ",
        MediaOrigin.rawURL("{{asset}}.png"),
        "cdn.example.com/a.png",
    ])
    func unusableURLReportsInvalidURL(url: String) async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let recorder = HealthRecorder()

        let window = mount(
            ImageSpec(url: url, blurHash: Self.blurHash), recorder: recorder, errorContent: Self.marker)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(recorder.all == [.init(campaignKey: Self.campaign, kind: .image, cause: "invalid_url")])
        #expect(MediaOrigin.totalRequestCount() == 0)
        expectStillUnderMarker(window)
    }

    /// The still's color shows at the corner and `errorContent` over it at the center.
    private func expectStillUnderMarker(_ window: UIWindow) {
        let image = rendered(window)
        let corner = pixel(of: image, atX: 0.05, y: 0.05)
        let still = BlurHashDecoder.decode(Self.blurHash, width: 32, height: 32)
            .flatMap { pixel(of: $0, atX: 0.05, y: 0.05) }
        #expect(corner != nil && still != nil)
        #expect(pixelsNearly(corner!, still!))
        let middle = centerPixel(of: image)
        #expect(middle != nil && pixelsNearly(middle!, Self.green, tolerance: 0.2))
    }

    // Fails if the SDK's image fetches stop sending the Digia User-Agent: the
    // `SDWebImageDownloader.shared.setValue(...)` line in DigiaImagePipeline.configureOnce. The
    // request log is what reached the (faked) wire from the real downloader.
    @Test("an image fetch sends the Digia User-Agent")
    func userAgentOnTheWire() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("ua.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target)

        let window = mount(ImageSpec(url: target.absoluteString))
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })
        #expect(MediaOrigin.requests(for: target).map(\.userAgent) == ["DigiaEngage/1.0 (iOS)"])
    }

    // Fails if a second render builds its own cache instead of sharing SDWebImage's: the plain
    // `WebImage(url:options:)` (shared manager) in MediaImage.body — adding `.refreshCached`
    // there refetches and fails this.
    @Test("a second render is a cache hit with no fetches")
    func secondRenderIsCacheHit() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("badge.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target)
        let red = RGB(r: 1, g: 0, b: 0)

        let first = mount(ImageSpec(url: target.absoluteString))
        #expect(await waitUntilMedia {
            renderedCenter(first).map { pixelsNearly($0, red) } ?? false
        })
        #expect(MediaOrigin.requests(for: target).count == 1)
        ComponentTestHost.unmount(first)

        let second = mount(ImageSpec(url: target.absoluteString))
        defer { ComponentTestHost.unmount(second) }
        #expect(await waitUntilMedia {
            renderedCenter(second).map { pixelsNearly($0, red) } ?? false
        })
        #expect(MediaOrigin.requests(for: target).count == 1)
    }
}
}

/// Pure rule tests: no rendering, no network.
@Suite("MediaImage decisions", .tags(.media, .unit))
struct MediaImageDecisionTests {
    // Fails if an unusable URL reaches the loader: `mediaUsableURL` in MediaSpec.swift.
    @Test("blank, templated and unparseable urls are unusable")
    func unusableURLs() {
        #expect(mediaUsableURL("") == nil)
        #expect(mediaUsableURL("   ") == nil)
        #expect(mediaUsableURL("https://cdn.example.com/{{asset}}.png") == nil)
        #expect(mediaUsableURL("http://[invalid") == nil)
        #expect(mediaUsableURL("cdn.example.com/a.png") == nil)
        #expect(mediaUsableURL("https://cdn.example.com/a.png") != nil)
    }

    // Fails if the blur is decoded on every render instead of once per hash: the
    // `cache.setObject` in BlurHashCache.image.
    @Test("a blurhash decodes once")
    func blurHashDecodesOnce() {
        let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        let first = BlurHashCache.image(for: hash, size: BlurHashPlaceholderView.decodeSize)
        let second = BlurHashCache.image(for: hash, size: BlurHashPlaceholderView.decodeSize)
        #expect(first != nil && first === second)
    }
}

final class SuccessCount { var count = 0 }
