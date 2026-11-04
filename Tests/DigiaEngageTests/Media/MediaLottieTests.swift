import Foundation
import Lottie
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The wrapper over a fake origin (`MediaOrigin`): `MediaLottie` loads through the real
// `loadLottieSource` (Lottie's own cache) and only the HTTP layer is faked. Each test below names the one production line whose change
// fails it; see ai_docs/meaningful-tests.md.

extension RenderedUITests {
@MainActor
@Suite("MediaLottie wrapper", .serialized, .tags(.media, .component))
struct MediaLottieComponentTests {
    private static let blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    private static let animation = Data(#"""
    {"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[]}
    """#.utf8)

    private func mount(_ spec: LottieSpec, recorder: HealthRecorder = HealthRecorder()) -> UIWindow {
        mountMedia(
            MediaLottie(spec: spec)
                .environment(\.digiaCampaignKey, "test-campaign")
                .environment(\.mediaServices, recorder.services)
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
        MediaOrigin.rawURL("{{anim}}.json"),
    ])
    func unusableURLsKeepStill(url: String) async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }

        let window = mount(LottieSpec(url: url, blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        _ = await waitUntilMedia(timeout: 1.0) { false }

        #expect(MediaOrigin.totalRequestCount() == 0)
        #expect(lottieViews(in: window).isEmpty)
        let middle = renderedCenter(window)
        let blur = blurCenter(Self.blurHash)
        #expect(middle != nil && blur != nil)
        #expect(pixelsNearly(middle!, blur!))
    }

    // Fails if a failed fetch leaves a hole instead of the still: the blur layer in
    // MediaLottie.body. Fails if the 404 is not attributed to the campaign, kind and cause: the
    // `services.reportHealth(campaignKey, .lottie, cause)` call in MediaLottie.load.
    @Test("a failed fetch keeps the still and reports http_4xx")
    func failedFetchKeepsStill() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("missing.json")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()

        let window = mount(LottieSpec(url: target.absoluteString, blurHash: Self.blurHash), recorder: recorder)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        #expect(recorder.all == [.init(campaignKey: "test-campaign", kind: .lottie, cause: "http_4xx")])
        ComponentTestHost.drainRunLoop(for: 0.2)
        let middle = renderedCenter(window)
        let blur = blurCenter(Self.blurHash)
        #expect(middle != nil && blur != nil)
        #expect(pixelsNearly(middle!, blur!))
    }

    // Fails if a parsed composition never reaches the animation view: the `source` handoff in
    // MediaLottie.load. A real animation through the real loader installs and plays per spec.
    @Test("a real animation installs and plays per the spec")
    func realAnimationPlays() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("ok.json")
        MediaOrigin.set(.status(200, Self.animation), for: target)

        let window = mount(LottieSpec(url: target.absoluteString, loop: true))
        defer { ComponentTestHost.unmount(window) }

        let view = await waitForAnimation(in: window)
        #expect(view != nil)
        #expect(view!.isAnimationPlaying)
        #expect(view!.loopMode == .loop)
    }

    private func waitForAnimation(in window: UIWindow) async -> LottieAnimationView? {
        _ = await waitUntilMedia { lottieViews(in: window).first?.animation != nil }
        ComponentTestHost.drainRunLoop(for: 0.1)
        return lottieViews(in: window).first(where: { $0.animation != nil })
    }
}
}
