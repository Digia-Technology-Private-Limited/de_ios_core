import Foundation
import Lottie
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The wrapper over a fake origin (`MediaOrigin`): `MediaLottie` loads through the real
// `loadLottieSource` (Lottie's own cache) and only the HTTP layer is faked. Each test below
// names the one production line whose change fails it; see ai_docs/meaningful-tests.md.

extension RenderedUITests {
@MainActor
@Suite("MediaLottie wrapper", .serialized, .tags(.media, .component))
struct MediaLottieComponentTests {
    private static let blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    private static let campaign = "test-campaign"
    /// An animation with no layers: it parses and plays, and draws nothing.
    private static let animation = Data(#"""
    {"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[]}
    """#.utf8)

    /// The marker `errorContent` draws: a green square in the middle of the box.
    private static let marker = AnyView(Color(red: 0, green: 0.5, blue: 0).frame(width: 40, height: 40))
    private static let green = RGB(r: 0, g: 0.5, b: 0)

    /// Lets a test switch the URL of a mounted wrapper.
    private final class Model: ObservableObject {
        @Published var url: String
        init(url: String) { self.url = url }
    }

    private struct Host: View {
        @ObservedObject var model: Model
        let recorder: HealthRecorder

        var body: some View {
            MediaLottie(spec: LottieSpec(url: model.url, blurHash: MediaLottieComponentTests.blurHash))
                .environment(\.digiaCampaignKey, MediaLottieComponentTests.campaign)
                .environment(\.mediaServices, recorder.services)
                .frame(width: 200, height: 200)
        }
    }

    private func mount(
        _ spec: LottieSpec, recorder: HealthRecorder = HealthRecorder(), errorContent: AnyView? = nil
    ) -> UIWindow {
        mountMedia(
            MediaLottie(spec: spec, errorContent: errorContent)
                .environment(\.digiaCampaignKey, Self.campaign)
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

    private func isBlur(_ window: UIWindow) -> Bool {
        guard let middle = renderedCenter(window), let blur = blurCenter(Self.blurHash) else { return false }
        return pixelsNearly(middle, blur)
    }

    private func waitForAnimation(in window: UIWindow) async -> LottieAnimationView? {
        _ = await waitUntilMedia { lottieViews(in: window).first?.animation != nil }
        ComponentTestHost.drainRunLoop(for: 0.1)
        return lottieViews(in: window).first(where: { $0.animation != nil })
    }

    // Fails if a blank, unresolved or schemeless URL reaches the loader or goes unreported: the
    // `mediaUsableURL` guard in MediaLottie.load. Fails if the label is dropped for it: the
    // `failed` flag it sets. The templated case rides the fake host so an attempted fetch would
    // be counted; no Lottie view mounts and the still covers the box.
    @Test("a blank, unresolved or schemeless url never fetches, keeps the still under errorContent, and reports invalid_url once", arguments: [
        "",
        "   ",
        MediaOrigin.rawURL("{{anim}}.json"),
        "cdn.example.com/a.json",
    ])
    func unusableURLReportsInvalidURL(url: String) async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let recorder = HealthRecorder()

        let window = mount(
            LottieSpec(url: url, blurHash: Self.blurHash), recorder: recorder, errorContent: Self.marker)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(recorder.all == [.init(campaignKey: Self.campaign, kind: .lottie, cause: "invalid_url")])
        #expect(MediaOrigin.totalRequestCount() == 0)
        #expect(lottieViews(in: window).isEmpty)
        let middle = renderedCenter(window)
        #expect(middle != nil && pixelsNearly(middle!, Self.green, tolerance: 0.2))
    }

    // Fails if a failed fetch leaves a hole instead of the still: the `MediaStill` in
    // MediaLottie.body. Fails if the 404 is not attributed to the campaign, kind and cause: the
    // `services.reportHealth(campaignKey, .lottie, cause)` call in MediaLottie.load.
    @Test("a failed fetch keeps the still and reports one http_4xx for the campaign")
    func failedFetchKeepsStill() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("missing.json")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()

        let window = mount(LottieSpec(url: target.absoluteString, blurHash: Self.blurHash), recorder: recorder)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(recorder.all == [.init(campaignKey: Self.campaign, kind: .lottie, cause: "http_4xx")])
        #expect(isBlur(window))
    }

    // Fails if a lost connection is reported: the `if let cause` guard in MediaLottie.load (a
    // fallback cause for a nil one reports it). The still and the label stay.
    @Test("a lost connection reports nothing and keeps the still under errorContent")
    func networkFailureReportsNothing() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("offline.json")
        MediaOrigin.set(.fail(.notConnectedToInternet), for: target)
        let recorder = HealthRecorder()

        let window = mount(
            LottieSpec(url: target.absoluteString, blurHash: Self.blurHash), recorder: recorder,
            errorContent: Self.marker)
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia {
            renderedCenter(window).map { pixelsNearly($0, Self.green, tolerance: 0.2) } ?? false
        })
        #expect(recorder.all.isEmpty)
    }

    // Fails if the blur survives once the animation is parsed: the `else` that shows
    // `MediaStill` only while there is no source in MediaLottie.body. Fails if the wrapper paints
    // a backdrop of its own: a transparent animation must show the white page behind it.
    @Test("the blur is gone once the animation loads, and nothing is painted behind a transparent one")
    func blurGoneAfterLoadAndNoBackdrop() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let target = MediaOrigin.url("held.json")
        MediaOrigin.set(.status(200, Self.animation), for: target, held: true)

        let window = mount(LottieSpec(url: target.absoluteString, blurHash: Self.blurHash, loop: true))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(isBlur(window))

        MediaOrigin.release(target)
        let view = await waitForAnimation(in: window)
        #expect(view != nil)
        ComponentTestHost.drainRunLoop(for: 0.3)
        let middle = renderedCenter(window)
        #expect(middle != nil && pixelsNearly(middle!, RGB(r: 1, g: 1, b: 1), tolerance: 0.02))
    }

    // Fails if the previous animation stays up while the next URL loads: the `source = nil` reset
    // at the top of MediaLottie.load.
    @Test("switching the url drops the old animation for the still while the new one loads")
    func urlChangeResetsState() async {
        MediaOrigin.install()
        defer { MediaOrigin.uninstall(); MediaOrigin.reset() }
        let first = MediaOrigin.url("first.json")
        let second = MediaOrigin.url("second.json")
        MediaOrigin.set(.status(200, Self.animation), for: first)
        MediaOrigin.set(.status(200, Self.animation), for: second, held: true)
        let model = Model(url: first.absoluteString)

        let window = mountMedia(Host(model: model, recorder: HealthRecorder()))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitForAnimation(in: window) != nil)

        model.url = second.absoluteString
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: second).isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(lottieViews(in: window).first(where: { $0.animation != nil }) == nil)
        #expect(isBlur(window))
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
}
}
