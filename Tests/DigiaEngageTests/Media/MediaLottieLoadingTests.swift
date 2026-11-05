import Foundation
import Lottie
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// What `MediaLottie` reports when an animation does not load, over the fake origin: which
// failures are health (a 4xx, a file that does not parse) and which are not (a server error), and
// that a failure is reported once however often the surface redraws. Lottie caches a composition
// by URL, so each test loads its own URL.

extension RenderedUITests {
@MainActor
@Suite("MediaLottie loading", .serialized, .tags(.media, .component))
struct MediaLottieLoadingTests {
    private static let blurHash = MediaFixtures.blurHash

    /// A wrapper a test can redraw without changing anything it reads.
    private struct Host: View {
        @ObservedObject var model: MediaModel

        var body: some View {
            let _ = model.redraws
            MediaLottie(url: model.url, blurHash: MediaLottieLoadingTests.blurHash)
        }
    }

    @Test("a zip without animations/ reports decode once")
    func dotLottieWithoutAnimationsReportsDecode() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("empty.lottie")
        MediaOrigin.set(.status(200, MediaFixtures.dotLottieWithoutAnimations), for: target)
        let recorder = HealthRecorder()

        let window = MediaStage.lottie(url: target.absoluteString, blurHash: Self.blurHash)
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .lottie, cause: "decode")])
        #expect(MediaStage.lottieViews(in: window).isEmpty)
    }

    @Test("invalid JSON served as 200 reports decode once")
    func invalidJSONReportsDecode() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("invalid.json")
        MediaOrigin.set(.status(200, Data("{ this is not json".utf8)), for: target)
        let recorder = HealthRecorder()

        let window = MediaStage.lottie(url: target.absoluteString, blurHash: Self.blurHash)
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .lottie, cause: "decode")])
        #expect(MediaStage.lottieViews(in: window).isEmpty)
    }

    @Test("a server error reports nothing")
    func serverErrorReportsNothing() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("busy.json")
        MediaOrigin.set(.status(503, Data("busy".utf8)), for: target)
        let recorder = HealthRecorder()
        let finished = MediaStage.countLottieLoads()

        let window = MediaStage.lottie(url: target.absoluteString, blurHash: Self.blurHash)
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { finished.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all.isEmpty)
        #expect(MediaStage.lottieViews(in: window).isEmpty)
    }

    @Test("an animation removed while loading reports nothing")
    func removedWhileLoadingReportsNothing() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("held-gone.json")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target, held: true)
        let recorder = HealthRecorder()
        let finished = MediaStage.countLottieLoads()

        let window = MediaStage.lottie(url: target.absoluteString, blurHash: Self.blurHash)
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })
        ComponentTestHost.unmount(window)
        MediaOrigin.release(target)
        #expect(await waitUntilMedia { finished.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all.isEmpty)
    }

    @Test("a failure is reported once, not again when the surface redraws (a 404)")
    func notFoundIsNotReportedAgainOnRedraw() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("gone.json")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()
        let model = MediaModel(url: target.absoluteString)

        let window = MediaStage.mount(Host(model: model))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        for _ in 0..<5 {
            model.redraw()
            ComponentTestHost.drainRunLoop(for: 0.1)
        }

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .lottie, cause: "http_4xx")])
        #expect(MediaOrigin.requests(for: target).count == 1)
    }

    @Test("a failure is reported once, not again when the surface redraws (an unusable url)")
    func unusableURLIsNotReportedAgainOnRedraw() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let recorder = HealthRecorder()
        let model = MediaModel(url: "")

        let window = MediaStage.mount(Host(model: model))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        for _ in 0..<5 {
            model.redraw()
            ComponentTestHost.drainRunLoop(for: 0.1)
        }

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .lottie, cause: "invalid_url")])
    }
}
}
