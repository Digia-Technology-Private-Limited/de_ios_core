import Foundation
import Lottie
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// How `MediaLottie` fits and plays an animation that loaded, over the fake origin. The animation
// is `MediaFixtures.markerAnimation`: an orange square that slides from the left to the right, so
// the frame on screen shows where the playhead is. Lottie caches a composition by URL, so each
// test loads its own URL.

extension RenderedUITests {
@MainActor
@Suite("MediaLottie playback", .serialized, .tags(.media, .component))
struct MediaLottiePlaybackTests {
    @Test("cover sizes the animation to fill the box", .tags(.golden))
    func coverSizesTheAnimation() async {
        await drawMarker(fit: .cover, golden: "lottie_fit_cover")
    }

    @Test("contain sizes the animation to fit inside the box", .tags(.golden))
    func containSizesTheAnimation() async {
        await drawMarker(fit: .contain, golden: "lottie_fit_contain")
    }

    @Test("fill stretches the animation to the box", .tags(.golden))
    func fillSizesTheAnimation() async {
        await drawMarker(fit: .fill, golden: "lottie_fit_fill")
    }

    private func drawMarker(fit: MediaFit, golden: String) async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("marker-\(fit.rawValue).json")
        MediaOrigin.set(.status(200, MediaFixtures.markerAnimation(frames: 60)), for: target)

        let window = MediaStage.lottie(url: target.absoluteString, fit: fit, autoplay: false)
        defer { ComponentTestHost.unmount(window) }
        #expect(await MediaStage.animationView(in: window) != nil)

        MediaStage.assertGolden(window, named: golden)
    }

    @Test("autoplay off holds the first frame")
    func autoplayOffHoldsTheFirstFrame() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("held-frame.json")
        MediaOrigin.set(.status(200, MediaFixtures.markerAnimation(frames: 6)), for: target)

        let window = MediaStage.lottie(url: target.absoluteString, autoplay: false)
        defer { ComponentTestHost.unmount(window) }
        let view = await MediaStage.animationView(in: window)
        ComponentTestHost.drainRunLoop(for: 0.6)

        #expect(view != nil)
        #expect(view?.isAnimationPlaying == false)
        #expect(view?.currentProgress == 0)
    }

    @Test("loop off plays once and stops on the last frame")
    func loopOffStopsOnTheLastFrame() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("play-once.json")
        MediaOrigin.set(.status(200, MediaFixtures.markerAnimation(frames: 6)), for: target)

        let window = MediaStage.lottie(url: target.absoluteString, loop: false)
        defer { ComponentTestHost.unmount(window) }
        let view = await MediaStage.animationView(in: window)
        _ = await waitUntilMedia { view?.isAnimationPlaying == false && view?.currentProgress == 1 }
        ComponentTestHost.drainRunLoop(for: 0.6)

        #expect(view?.isAnimationPlaying == false)
        #expect(view?.currentProgress == 1)
    }

    @Test("loop on starts again after the last frame")
    func loopOnStartsAgain() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("play-forever.json")
        MediaOrigin.set(.status(200, MediaFixtures.markerAnimation(frames: 6)), for: target)

        let window = MediaStage.lottie(url: target.absoluteString, loop: true)
        defer { ComponentTestHost.unmount(window) }
        let view = await MediaStage.animationView(in: window)
        // The animation lasts 0.2 s; a second is five passes.
        ComponentTestHost.drainRunLoop(for: 1.0)

        #expect(view?.isAnimationPlaying == true)
        #expect(view?.loopMode == .loop)
    }

    @Test("a pinned frame draws that frame and does not play", .tags(.golden))
    func pinnedFrameDoesNotPlay() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("pinned.json")
        MediaOrigin.set(.status(200, MediaFixtures.markerAnimation(frames: 60)), for: target)

        let window = MediaStage.lottie(url: target.absoluteString, autoplay: true, freezeAt: 0.5)
        defer { ComponentTestHost.unmount(window) }
        let view = await MediaStage.animationView(in: window)
        ComponentTestHost.drainRunLoop(for: 0.5)

        #expect(view?.isAnimationPlaying == false)
        #expect(view?.currentProgress == 0.5)
        MediaStage.assertGolden(window, named: "lottie_pinned_half")
    }

    @Test("a dotLottie (.lottie zip) loads and draws", .tags(.golden))
    func dotLottieLoadsAndDraws() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("host-animation.lottie")
        MediaOrigin.set(.status(200, try testkitAsset("lottie-host-animation.lottie")), for: target)

        let window = MediaStage.lottie(url: target.absoluteString, autoplay: false)
        defer { ComponentTestHost.unmount(window) }
        #expect(await MediaStage.animationView(in: window) != nil)

        MediaStage.assertGolden(window, named: "lottie_dotlottie_loaded")
    }

    @Test("a dotLottie (.lottie zip) plays")
    func dotLottiePlays() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("host-animation-plays.lottie")
        MediaOrigin.set(.status(200, try testkitAsset("lottie-host-animation.lottie")), for: target)

        let window = MediaStage.lottie(url: target.absoluteString, loop: true)
        defer { ComponentTestHost.unmount(window) }
        let view = await MediaStage.animationView(in: window)
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(view?.isAnimationPlaying == true)
        #expect(view?.loopMode == .loop)
    }
}
}
