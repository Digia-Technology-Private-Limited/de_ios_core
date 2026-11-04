import Foundation
import SDWebImage
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The wrapper over a fake origin (`MediaOrigin`): `MediaImage` renders through the real SDWebImage
// downloader and cache, and only the HTTP layer is faked, so what is asserted is what the SDK
// ships. Every picture is drawn on the one `MediaStage`; what is on screen is proved by the
// goldens, and the other tests assert callbacks, request logs and health records.

extension RenderedUITests {
@MainActor
@Suite("MediaImage wrapper", .serialized, .tags(.media, .component))
struct MediaImageComponentTests {
    private static let blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"

    private func mount(
        _ spec: ImageSpec, onSuccess: (() -> Void)? = nil, onFailure: (() -> Void)? = nil
    ) -> UIWindow {
        MediaStage.mount(MediaImage(spec: spec, onSuccess: onSuccess, onFailure: onFailure))
    }

    @Test("shows the authored blur while the picture is on its way", .tags(.golden))
    func blurWhileLoading() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("held.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target, held: true)
        let recorder = HealthRecorder()

        let window = mount(ImageSpec(url: target.absoluteString, blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })

        #expect(recorder.all.isEmpty)
        MediaStage.assertGolden(window, named: "image_blur_loading")
        MediaOrigin.release(target)
    }

    @Test("shows nothing while the picture is on its way when no blur is authored", .tags(.golden))
    func nothingWhileLoadingWithoutBlur() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("held-no-blur.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target, held: true)
        let recorder = HealthRecorder()

        let window = mount(ImageSpec(url: target.absoluteString))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })

        #expect(recorder.all.isEmpty)
        MediaStage.assertGolden(window, named: "image_loading_no_blur")
        MediaOrigin.release(target)
    }

    @Test("shows the blur when the picture was never uploaded", .tags(.golden))
    func blurWhenNeverUploaded() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("never-uploaded.jpg")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let failures = CallCount()

        let window = mount(
            ImageSpec(url: target.absoluteString, blurHash: Self.blurHash), onFailure: { failures.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })

        #expect(MediaOrigin.requests(for: target).count == 1)
        MediaStage.assertGolden(window, named: "image_error_blur")
    }

    @Test("leaves no blur behind a loaded picture", .tags(.golden))
    func noBlurBehindLoadedPicture() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("testkit-badge.svg")
        MediaOrigin.set(.status(200, try testkitAsset("testkit-badge.svg")), for: target, held: true)
        let successes = CallCount()

        let window = mount(
            ImageSpec(url: target.absoluteString, fit: .contain, blurHash: Self.blurHash),
            onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })
        MediaOrigin.release(target)
        #expect(await waitUntilMedia { successes.value > 0 })

        MediaStage.assertGolden(window, named: "image_loaded")
    }

    @Test("reports success once when the picture finishes loading")
    func reportsSuccessOnce() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("held.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target, held: true)
        let successes = CallCount()

        let window = mount(ImageSpec(url: target.absoluteString), onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })
        MediaOrigin.release(target)
        #expect(await waitUntilMedia { successes.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.5)

        #expect(successes.value == 1)
    }

    @Test("reports an error once when the picture cannot load")
    func reportsErrorOnce() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("never-uploaded.jpg")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let failures = CallCount()

        let window = mount(ImageSpec(url: target.absoluteString), onFailure: { failures.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.5)

        #expect(failures.value == 1)
    }

    @Test("a second render of the same picture is a cache hit with no fetches")
    func secondRenderIsCacheHit() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("badge.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target)
        let firstSuccesses = CallCount()
        let secondSuccesses = CallCount()

        let first = mount(ImageSpec(url: target.absoluteString), onSuccess: { firstSuccesses.value += 1 })
        #expect(await waitUntilMedia { firstSuccesses.value > 0 })
        #expect(MediaOrigin.requests(for: target).count == 1)
        ComponentTestHost.unmount(first)

        let second = mount(ImageSpec(url: target.absoluteString), onSuccess: { secondSuccesses.value += 1 })
        defer { ComponentTestHost.unmount(second) }
        #expect(await waitUntilMedia { secondSuccesses.value > 0 })

        #expect(MediaOrigin.requests(for: target).count == 1)
    }

    @Test("a picture already in the memory cache draws on the first render, reported once, leaving no blur", arguments: [
        false, true,
    ])
    func cachedPictureDrawsOnFirstRender(withBlurHash: Bool) async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("cached.png")
        let picture = try #require(UIImage(data: halfTransparentPNG()))
        SDImageCache.shared.storeImage(toMemory: picture, forKey: target.absoluteString)
        defer { SDImageCache.shared.removeImageFromMemory(forKey: target.absoluteString) }
        try #require(SDImageCache.shared.imageFromMemoryCache(forKey: target.absoluteString) != nil)
        let successes = CallCount()

        let window = mount(
            ImageSpec(url: target.absoluteString, blurHash: withBlurHash ? Self.blurHash : nil),
            onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        // The picture's opaque left half is red; its transparent right half shows the host's teal
        // stripe through, not a stale blur. The stage's box is x 75...315, y 362...482.
        let drawn = ComponentTestHost.renderImage(of: window)
        let left = pixelColor(of: drawn, atX: 135, y: 440)
        let right = pixelColor(of: drawn, atX: 255, y: 440)
        #expect(left.map { colorsNearly($0, .red) } == true)
        #expect(right.map { colorsNearly($0, ComponentTestHost.hostTeal) } == true)
        #expect(successes.value == 1)
        #expect(MediaOrigin.requests(for: target).isEmpty)
    }

    @Test("a 404 reports one http_4xx against its campaign")
    func notFoundReports() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("missing.png")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()

        let window = mount(ImageSpec(url: target.absoluteString, blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .image, cause: "http_4xx")])
    }

    @Test("a server error or a lost connection reports nothing", arguments: [
        MediaOrigin.Reply.status(503, Data("busy".utf8)),
        MediaOrigin.Reply.fail(.notConnectedToInternet),
    ])
    func serverAndNetworkFailuresReportNothing(reply: MediaOrigin.Reply) async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("flaky.png")
        MediaOrigin.set(reply, for: target)
        let recorder = HealthRecorder()
        let failures = CallCount()

        let window = mount(
            ImageSpec(url: target.absoluteString, blurHash: Self.blurHash), onFailure: { failures.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all.isEmpty)
    }

    @Test("a blank, unresolved or schemeless url never fetches and reports invalid_url once", arguments: [
        "",
        "   ",
        MediaOrigin.rawURL("{{asset}}.png"),
        "cdn.example.com/a.png",
    ])
    func unusableURLReportsInvalidURL(url: String) async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let recorder = HealthRecorder()

        let window = mount(ImageSpec(url: url, blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .image, cause: "invalid_url")])
        #expect(MediaOrigin.totalRequestCount() == 0)
    }

    @Test("every image request reaches the server with the Digia User-Agent")
    func userAgentOnTheWire() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("ua.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target)

        let window = mount(ImageSpec(url: target.absoluteString))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })

        #expect(MediaOrigin.requests(for: target).map(\.userAgent) == ["DigiaEngage/1.0 (iOS)"])
    }
}
}

/// Pure rule tests: no rendering, no network.
@Suite("MediaImage decisions", .tags(.media, .unit))
struct MediaImageDecisionTests {
    @Test("blank, templated and unparseable urls are unusable")
    func unusableURLs() {
        #expect(mediaUsableURL("") == nil)
        #expect(mediaUsableURL("   ") == nil)
        #expect(mediaUsableURL("https://cdn.example.com/{{asset}}.png") == nil)
        #expect(mediaUsableURL("http://[invalid") == nil)
        #expect(mediaUsableURL("cdn.example.com/a.png") == nil)
        #expect(mediaUsableURL("https://cdn.example.com/a.png") != nil)
    }

    @Test("a blurhash decodes once")
    func blurHashDecodesOnce() {
        let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        let first = BlurHashCache.image(for: hash, size: BlurHashPlaceholderView.decodeSize)
        let second = BlurHashCache.image(for: hash, size: BlurHashPlaceholderView.decodeSize)
        #expect(first != nil && first === second)
    }
}
