import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// GIF and WebP pictures through `MediaImage` over the fake origin. // `media/two-frames.gif` holds each frame for a second: the first-frame golden is taken well inside
// the first second, the second-frame one in the middle of the second.

extension RenderedUITests {
@MainActor
@Suite("MediaImage GIF and WebP", .serialized, .tags(.media, .component))
struct MediaImageAnimatedTests {
    @Test("an animated GIF loads and reports success once", .tags(.golden))
    func gifLoadsAndReportsSuccessOnce() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("two-frames.gif")
        MediaOrigin.set(.status(200, MediaFixtures.twoFrames), for: target)
        let recorder = HealthRecorder()
        let successes = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, fit: .contain, onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value > 0 })

        #expect(successes.value == 1)
        #expect(recorder.all.isEmpty)
        MediaStage.assertGolden(window, named: "image_gif_first_frame")
    }

    @Test("an animated GIF advances past its first frame", .tags(.golden))
    func gifAdvancesPastFirstFrame() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("plays-on.gif")
        MediaOrigin.set(.status(200, MediaFixtures.twoFrames), for: target)
        let successes = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, fit: .contain, onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value > 0 })
        ComponentTestHost.drainRunLoop(for: 1.1)

        MediaStage.assertGolden(window, named: "image_gif_second_frame")
    }

    @Test("a static WebP loads and reports success once", .tags(.golden))
    func webPLoadsAndReportsSuccessOnce() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("picture.webp")
        MediaOrigin.set(.status(200, MediaFixtures.quadrantsWebP), for: target)
        let recorder = HealthRecorder()
        let successes = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, fit: .contain, onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(successes.value == 1)
        #expect(recorder.all.isEmpty)
        MediaStage.assertGolden(window, named: "image_webp_loaded")
    }

    @Test("a GIF that cannot be decoded reports decode once")
    func brokenGIFReportsDecode() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("broken.gif")
        MediaOrigin.set(.status(200, MediaFixtures.brokenGIF), for: target)
        let recorder = HealthRecorder()
        let failures = CallCount()

        let window = MediaStage.image(url: target.absoluteString, onFailure: { failures.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .image, cause: "decode")])
        #expect(failures.value == 1)
    }
}
}
