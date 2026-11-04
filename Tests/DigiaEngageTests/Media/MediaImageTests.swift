import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The wrapper + fake network seam (D5): `MediaImage` renders through the real SDWebImage stack
// and only the HTTP layer is faked (`FakeImageLoader`). Each test below names the one
// production line whose change fails it; see ai_docs/meaningful-tests.md.

extension RenderedUITests {
@MainActor
@Suite("MediaImage wrapper", .serialized, .tags(.media, .component))
struct MediaImageComponentTests {
    private static let blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    // A 4x4 red square: answers the fetch and fills the box solid red.
    private static let redDot: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }()

    private func mount(_ spec: ImageSpec, box: CauseBox? = nil) -> UIWindow {
        mountMedia(
            MediaImage(
                spec: spec,
                onFailure: box.map { capture in { capture.record($0) } }
            )
            .environment(\.digiaCampaignKey, "test-campaign")
            .environment(\.mediaImageLoader, FakeImageLoader.shared)
            .frame(width: 200, height: 200)
        )
    }

    private func renderedCenter(_ window: UIWindow) -> RGB? {
        centerPixel(of: ComponentTestHost.renderImage(of: window.rootViewController!.view))
    }

    // Fails if the blur is not the bottom layer while the fetch is in flight: the blur-still
    // branch in MediaImage.body. The count proves the fetch really started (else the still
    // would show vacuously).
    @Test("the authored blurhash shows while the picture is on its way")
    func blurShowsWhileLoading() async {
        defer { FakeImageLoader.reset() }
        let target = FakeImageLoader.url("loading.png")
        FakeImageLoader.set(.hang, for: target)
        let box = CauseBox()

        let window = mount(ImageSpec(url: target.absoluteString, blurHash: Self.blurHash), box: box)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { FakeImageLoader.requestCount(for: target) > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)
        let middle = renderedCenter(window)
        let blur = blurCenter(Self.blurHash)
        #expect(middle != nil && blur != nil)
        #expect(pixelsNearly(middle!, blur!))
        #expect(box.all.isEmpty)
    }

    // Fails if an error leaves a hole instead of the still: the clear-placeholder WebImage over
    // the blur layer in MediaImage.body. Fails if the 404 is not attributed: the
    // `mediaFailureCause(imageError:) ?? "network"` cause in MediaImage.onFailure.
    @Test("a picture the server 404s keeps the authored blur and reports http_4xx")
    func errorKeepsBlurAndReportsCause() async {
        defer { FakeImageLoader.reset() }
        let target = FakeImageLoader.url("missing.png")
        FakeImageLoader.set(.error(FakeImageLoader.httpError(status: 404)), for: target)
        let box = CauseBox()

        let window = mount(ImageSpec(url: target.absoluteString, blurHash: Self.blurHash), box: box)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !box.all.isEmpty })
        #expect(box.all == ["http_4xx"])
        ComponentTestHost.drainRunLoop(for: 0.2)
        let middle = renderedCenter(window)
        let blur = blurCenter(Self.blurHash)
        #expect(middle != nil && blur != nil)
        #expect(pixelsNearly(middle!, blur!))
    }

    // Fails if a transport failure reports nothing: the `?? "network"` fallback in
    // MediaImage.onFailure (without it the shared mapper returns nil and the event is dropped).
    @Test("a network failure still reports a non-nil cause")
    func networkFailureReportsNetwork() async {
        defer { FakeImageLoader.reset() }
        let target = FakeImageLoader.url("offline.png")
        FakeImageLoader.set(.error(URLError(.notConnectedToInternet) as NSError), for: target)
        let box = CauseBox()

        let window = mount(ImageSpec(url: target.absoluteString, blurHash: Self.blurHash), box: box)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !box.all.isEmpty })
        #expect(box.all == ["network"])
        ComponentTestHost.drainRunLoop(for: 0.2)
        let middle = renderedCenter(window)
        let blur = blurCenter(Self.blurHash)
        #expect(middle != nil && blur != nil)
        #expect(pixelsNearly(middle!, blur!))
    }

    // Fails if a second render builds its own cache instead of sharing SDWebImage's: the plain
    // `WebImage(url:options:)` (shared manager) in MediaImage.body — adding `.refreshCached`
    // there refetches and fails this.
    @Test("a second render is a cache hit with no fetches")
    func secondRenderIsCacheHit() async {
        defer { FakeImageLoader.reset() }
        let target = FakeImageLoader.url("badge.png")
        FakeImageLoader.set(.image(Self.redDot), for: target)
        let red = RGB(r: 1, g: 0, b: 0)

        let first = mount(ImageSpec(url: target.absoluteString))
        #expect(await waitUntilMedia {
            renderedCenter(first).map { pixelsNearly($0, red) } ?? false
        })
        #expect(FakeImageLoader.requestCount(for: target) == 1)
        ComponentTestHost.unmount(first)

        let second = mount(ImageSpec(url: target.absoluteString))
        defer { ComponentTestHost.unmount(second) }
        #expect(await waitUntilMedia {
            renderedCenter(second).map { pixelsNearly($0, red) } ?? false
        })
        #expect(FakeImageLoader.requestCount(for: target) == 1)
    }

    // Fails if the spinner rule moves: `showsSpinner(hasBlurStill:waited:)` in MediaImage (the
    // view wires its 400ms arm to it). No blur + a hanging load: no spinner right after mount,
    // spinner once the wait crosses the delay.
    @Test("the spinner waits for the delay and only without a still")
    func spinnerWaitsForDelay() async {
        defer { FakeImageLoader.reset() }
        let target = FakeImageLoader.url("slow.png")
        FakeImageLoader.set(.hang, for: target)

        let window = mount(ImageSpec(url: target.absoluteString))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { FakeImageLoader.requestCount(for: target) > 0 })

        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(!hasActivityIndicator(in: window))
        #expect(await waitUntilMedia(timeout: 5.0) { hasActivityIndicator(in: window) })
    }
}
}

/// Pure mapping and rule tests: no rendering, no network.
@Suite("MediaImage decisions", .tags(.media, .unit))
struct MediaImageDecisionTests {
    // Fails if the 400ms boundary moves or a blur stops suppressing the spinner:
    // `MediaImage.showsSpinner(hasBlurStill:waited:)`.
    @Test("the spinner rule honors the blur and the delay boundary")
    func spinnerRule() {
        #expect(!MediaImage.showsSpinner(hasBlurStill: true, waited: 10))
        #expect(!MediaImage.showsSpinner(hasBlurStill: false, waited: 0.39))
        #expect(MediaImage.showsSpinner(hasBlurStill: false, waited: 0.4))
        #expect(MediaImage.showsSpinner(hasBlurStill: false, waited: 5))
    }

    // Fails if an unusable URL reaches the loader: `mediaUsableURL` in MediaSpec.swift.
    @Test("blank, templated and unparseable urls are unusable")
    func unusableURLs() {
        #expect(mediaUsableURL("") == nil)
        #expect(mediaUsableURL("   ") == nil)
        #expect(mediaUsableURL("https://cdn.example.com/{{asset}}.png") == nil)
        #expect(mediaUsableURL("http://[invalid") == nil)
        #expect(mediaUsableURL("https://cdn.example.com/a.png") != nil)
    }
}
