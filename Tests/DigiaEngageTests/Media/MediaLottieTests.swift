import Foundation
import Lottie
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The wrapper + fake network seam (D5): `MediaLottie` loads through the real `loadLottieSource`
// (Lottie's own cache, D6) and only the HTTP layer is faked (`FakeMediaOrigin`, which also
// intercepts `URLSession.shared`). Each test below names the one production line whose change
// fails it; see ai_docs/meaningful-tests.md.

extension RenderedUITests {
@MainActor
@Suite("MediaLottie wrapper", .serialized, .tags(.media, .component))
struct MediaLottieComponentTests {
    private static let blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    private static let animation = Data(#"""
    {"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[]}
    """#.utf8)

    private func mount(_ spec: LottieSpec, box: CauseBox? = nil) -> UIWindow {
        mountMedia(
            MediaLottie(
                spec: spec,
                onFailure: box.map { capture in { capture.record($0) } }
            )
            .environment(\.digiaCampaignKey, "test-campaign")
            .frame(width: 200, height: 200)
        )
    }

    private func lottieViews(in window: UIWindow) -> [LottieAnimationView] {
        var found: [LottieAnimationView] = []
        func walk(_ view: UIView) {
            if let lottie = view as? LottieAnimationView { found.append(lottie) }
            view.subviews.forEach(walk)
        }
        if let root = window.rootViewController?.view { walk(root) }
        return found
    }

    private func renderedCenter(_ window: UIWindow) -> RGB? {
        centerPixel(of: ComponentTestHost.renderImage(of: window.rootViewController!.view))
    }

    // Fails if an unusable URL reaches the loader: the `mediaUsableURL` guard in
    // MediaLottie.load. The templated case rides the fake host so an attempted fetch is
    // counted; the other two can never form a request. No Lottie view mounts and the still
    // covers the box.
    @Test("blank and templated urls never fetch and keep the still", arguments: [
        "",
        "http://[invalid",
        FakeMediaOrigin.rawURL("{{anim}}.json"),
    ])
    func unusableURLsKeepStill(url: String) async {
        FakeMediaOrigin.install()
        defer {
            FakeMediaOrigin.uninstall()
            FakeMediaOrigin.reset()
        }

        let window = mount(LottieSpec(url: url, blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        _ = await waitUntilMedia(timeout: 1.0) { false }

        #expect(FakeMediaOrigin.totalRequestCount() == 0)
        #expect(lottieViews(in: window).isEmpty)
        let middle = renderedCenter(window)
        let blur = blurCenter(Self.blurHash)
        #expect(middle != nil && blur != nil)
        #expect(pixelsNearly(middle!, blur!))
    }

    // Fails if a failed fetch leaves a hole instead of the still: the backdrop + blur layer in
    // MediaLottie.body. Fails if the 404 is not attributed: the `?? "network"` cause in
    // MediaLottie.load.
    @Test("a failed fetch keeps the still and reports http_4xx")
    func failedFetchKeepsStill() async {
        FakeMediaOrigin.install()
        defer {
            FakeMediaOrigin.uninstall()
            FakeMediaOrigin.reset()
        }
        let target = FakeMediaOrigin.url("missing.json")
        FakeMediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let box = CauseBox()

        let window = mount(LottieSpec(url: target.absoluteString, blurHash: Self.blurHash), box: box)
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
    // MediaLottie.load (without it `loadLottieSource` returns a nil cause and the event drops).
    @Test("a network failure still reports a non-nil cause")
    func networkFailureReportsNetwork() async {
        FakeMediaOrigin.install()
        defer {
            FakeMediaOrigin.uninstall()
            FakeMediaOrigin.reset()
        }
        let target = FakeMediaOrigin.url("offline.json")
        FakeMediaOrigin.set(.fail(.notConnectedToInternet), for: target)
        let box = CauseBox()

        let window = mount(LottieSpec(url: target.absoluteString, blurHash: Self.blurHash), box: box)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !box.all.isEmpty })
        #expect(box.all == ["network"])
    }

    // Fails if a parsed composition never reaches the animation view: the `source` handoff in
    // MediaLottie.load. A real animation through the real loader installs and plays per spec.
    @Test("a real animation installs and plays per the spec")
    func realAnimationPlays() async {
        FakeMediaOrigin.install()
        defer {
            FakeMediaOrigin.uninstall()
            FakeMediaOrigin.reset()
        }
        let target = FakeMediaOrigin.url("ok.json")
        FakeMediaOrigin.set(.status(200, Self.animation), for: target)

        let window = mount(LottieSpec(url: target.absoluteString, loop: true))
        defer { ComponentTestHost.unmount(window) }

        let view = await waitForAnimation(in: window)
        #expect(view != nil)
        #expect(view!.isAnimationPlaying)
        #expect(view!.loopMode == .loop)
    }

    // Fails if the bottom layer is empty with no still: `Color.mediaBackdrop` in
    // MediaLottie.body. Without a blur and with no fetch, the box is the dark backdrop.
    @Test("no still means the dark backdrop, not an empty box")
    func backdropWithoutStill() async {
        FakeMediaOrigin.install()
        defer {
            FakeMediaOrigin.uninstall()
            FakeMediaOrigin.reset()
        }

        let window = mount(LottieSpec(url: ""))
        defer { ComponentTestHost.unmount(window) }
        _ = await waitUntilMedia(timeout: 1.0) { false }

        let middle = renderedCenter(window)
        #expect(middle != nil)
        #expect(pixelsNearly(middle!, RGB(r: 0.10, g: 0.10, b: 0.10), tolerance: 0.05))
    }

    private func waitForAnimation(in window: UIWindow) async -> LottieAnimationView? {
        _ = await waitUntilMedia { lottieViews(in: window).first?.animation != nil }
        ComponentTestHost.drainRunLoop(for: 0.1)
        return lottieViews(in: window).first(where: { $0.animation != nil })
    }
}
}

/// Pure mapping tests: no rendering, no network.
@Suite("MediaLottie decisions", .tags(.media, .unit))
struct MediaLottieDecisionTests {
    // Fails if a fit maps to the wrong Lottie content mode: `MediaFit.viewContentMode`.
    @Test("fits map to lottie content modes")
    func fitMapping() {
        #expect(MediaFit.cover.viewContentMode == .scaleAspectFill)
        #expect(MediaFit.contain.viewContentMode == .scaleAspectFit)
        #expect(MediaFit.fill.viewContentMode == .scaleToFill)
    }
}
