import Foundation
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

    private func mount(_ spec: ImageSpec, recorder: HealthRecorder = HealthRecorder()) -> UIWindow {
        mountMedia(
            MediaImage(spec: spec)
                .environment(\.digiaCampaignKey, Self.campaign)
                .environment(\.mediaServices, recorder.services)
                .frame(width: 200, height: 200)
        )
    }

    private func renderedCenter(_ window: UIWindow) -> RGB? {
        centerPixel(of: ComponentTestHost.renderImage(of: window.rootViewController!.view))
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
    // MediaImage.body. Fails if the failure is not attributed to the campaign, kind and cause:
    // the `services.reportHealth(campaignKey, .image, cause)` call in MediaImage.onFailure.
    @Test("a picture the server 404s keeps the still and reports one http_4xx for the campaign")
    func notFoundKeepsStillAndReports() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("missing.png")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()

        let window = mount(ImageSpec(url: target.absoluteString, blurHash: Self.blurHash), recorder: recorder)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(recorder.all == [.init(campaignKey: Self.campaign, kind: .image, cause: "http_4xx")])
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
        #expect(mediaUsableURL("https://cdn.example.com/a.png") != nil)
    }
}
