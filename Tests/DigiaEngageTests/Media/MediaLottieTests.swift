import Foundation
import Lottie
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The wrapper over a fake origin (`MediaLottie` loads through the real `loadLottieSource`, with
// Lottie's own cache) with only the HTTP layer faked. Every animation is drawn on the one
// `MediaStage`; what is on screen is proved by the goldens, and the other tests assert the health
// records and the animation view. Lottie caches a composition by URL, so each test (held ones
// included) loads its own URL.

extension RenderedUITests {
@MainActor
@Suite("MediaLottie wrapper", .serialized, .tags(.media, .component))
struct MediaLottieComponentTests {
    private static let blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    /// An animation with no layers: it parses and plays, and draws nothing.
    private static let animation = Data(#"""
    {"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[]}
    """#.utf8)

    /// Lets a test switch the URL of a mounted wrapper.
    private final class Model: ObservableObject {
        @Published var url: String
        init(url: String) { self.url = url }
    }

    private struct Host: View {
        @ObservedObject var model: Model

        var body: some View {
            MediaLottie(spec: LottieSpec(url: model.url, blurHash: MediaLottieComponentTests.blurHash))
        }
    }

    private func mount(_ spec: LottieSpec) -> UIWindow {
        MediaStage.mount(MediaLottie(spec: spec))
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

    private func waitForAnimation(in window: UIWindow) async -> LottieAnimationView? {
        _ = await waitUntilMedia { lottieViews(in: window).first?.animation != nil }
        ComponentTestHost.drainRunLoop(for: 0.1)
        return lottieViews(in: window).first(where: { $0.animation != nil })
    }

    @Test("shows the authored blur while the animation is on its way", .tags(.golden))
    func blurWhileLoading() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("static-lottie.json")
        MediaOrigin.set(.status(200, try testkitAsset("static-lottie.json")), for: target, held: true)
        let recorder = HealthRecorder()

        let window = mount(LottieSpec(url: target.absoluteString, blurHash: Self.blurHash, autoplay: false))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })

        #expect(recorder.all.isEmpty)
        MediaStage.assertGolden(window, named: "lottie_blur_loading")
        MediaOrigin.release(target)
    }

    @Test("shows nothing while the animation is on its way when no blur is authored", .tags(.golden))
    func nothingWhileLoadingWithoutBlur() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("static-lottie.json")
        MediaOrigin.set(.status(200, try testkitAsset("static-lottie.json")), for: target, held: true)
        let recorder = HealthRecorder()

        let window = mount(LottieSpec(url: target.absoluteString, autoplay: false))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })

        #expect(recorder.all.isEmpty)
        MediaStage.assertGolden(window, named: "lottie_loading_no_blur")
        MediaOrigin.release(target)
    }

    @Test("shows the blur when the animation cannot load", .tags(.golden))
    func blurWhenItCannotLoad() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("nope.json")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()

        let window = mount(LottieSpec(url: target.absoluteString, blurHash: Self.blurHash, autoplay: false))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })

        MediaStage.assertGolden(window, named: "lottie_error_placeholder")
    }

    @Test("a blank url shows the blur", .tags(.golden))
    func blankURLShowsBlur() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let recorder = HealthRecorder()

        let window = mount(LottieSpec(url: "", blurHash: Self.blurHash, autoplay: false))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })

        MediaStage.assertGolden(window, named: "lottie_blank_url")
    }

    @Test("a blank url shows nothing when no blur is authored", .tags(.golden))
    func blankURLShowsNothingWithoutBlur() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let recorder = HealthRecorder()

        let window = mount(LottieSpec(url: "", autoplay: false))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })

        MediaStage.assertGolden(window, named: "lottie_blank_url_no_hash")
    }

    @Test("a loaded animation leaves no blur or backdrop behind it", .tags(.golden))
    func noBlurOrBackdropBehindLoadedAnimation() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("static-lottie.json")
        MediaOrigin.set(.status(200, try testkitAsset("static-lottie.json")), for: target, held: true)

        let window = mount(LottieSpec(url: target.absoluteString, blurHash: Self.blurHash, autoplay: false))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })
        MediaOrigin.release(target)

        #expect(await waitForAnimation(in: window) != nil)
        MediaStage.assertGolden(window, named: "lottie_loaded")
    }

    @Test("a blank, unresolved or schemeless url never fetches and reports invalid_url once", arguments: [
        "",
        "   ",
        MediaOrigin.rawURL("{{anim}}.json"),
        "cdn.example.com/a.json",
    ])
    func unusableURLReportsInvalidURL(url: String) async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let recorder = HealthRecorder()

        let window = mount(LottieSpec(url: url, blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .lottie, cause: "invalid_url")])
        #expect(MediaOrigin.totalRequestCount() == 0)
        #expect(lottieViews(in: window).isEmpty)
    }

    @Test("a failed animation reports its media kind and campaign")
    func failedAnimationReports() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("missing.json")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()

        let window = mount(LottieSpec(url: target.absoluteString, blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .lottie, cause: "http_4xx")])
    }

    @Test("a lost connection reports nothing")
    func networkFailureReportsNothing() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("offline.json")
        MediaOrigin.set(.fail(.notConnectedToInternet), for: target)
        let recorder = HealthRecorder()
        let finished = CallCount()
        MediaServices.override(loadLottie: { url in
            let loaded = await MediaServices.sdk.loadLottie(url)
            await MainActor.run { finished.value += 1 }
            return loaded
        })

        let window = mount(LottieSpec(url: target.absoluteString, blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { finished.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all.isEmpty)
        #expect(lottieViews(in: window).isEmpty)
    }

    @Test("switching the url drops the old animation while the new one loads")
    func urlChangeDropsOldAnimation() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let first = MediaOrigin.url("first.json")
        let second = MediaOrigin.url("second.json")
        MediaOrigin.set(.status(200, Self.animation), for: first)
        MediaOrigin.set(.status(200, Self.animation), for: second, held: true)
        let model = Model(url: first.absoluteString)

        let window = MediaStage.mount(Host(model: model))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitForAnimation(in: window) != nil)

        model.url = second.absoluteString
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: second).isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(lottieViews(in: window).first(where: { $0.animation != nil }) == nil)
        MediaOrigin.release(second)
    }

    @Test("a real animation installs and plays per the spec")
    func realAnimationPlays() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("ok.json")
        MediaOrigin.set(.status(200, Self.animation), for: target)

        let window = mount(LottieSpec(url: target.absoluteString, loop: true))
        defer { ComponentTestHost.unmount(window) }
        let view = await waitForAnimation(in: window)

        #expect(view != nil)
        #expect(view?.isAnimationPlaying == true)
        #expect(view?.loopMode == .loop)
    }
}
}
