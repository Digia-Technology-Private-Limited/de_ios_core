import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// SVG pictures through `MediaImage` over the fake origin. The vector is the Test Kit badge
// (`testkit-badge.svg`), the same file the canvas goldens use.

extension RenderedUITests {
@MainActor
@Suite("MediaImage vectors", .serialized, .tags(.media, .component))
struct MediaImageVectorTests {
    private static let blurHash = MediaFixtures.blurHash

    @Test("a vector is drawn and reports success once", .tags(.golden))
    func vectorIsDrawnAndReportsSuccessOnce() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("badge.svg")
        MediaOrigin.set(.status(200, try testkitAsset("testkit-badge.svg")), for: target)
        let recorder = HealthRecorder()
        let successes = CallCount()

        let window = MediaStage.image(url: target.absoluteString, onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(successes.value == 1)
        #expect(recorder.all.isEmpty)
        MediaStage.assertGolden(window, named: "image_svg_loaded")
    }

    @Test("a vector fits per contain", .tags(.golden))
    func vectorFitsPerContain() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("badge-contain.svg")
        MediaOrigin.set(.status(200, try testkitAsset("testkit-badge.svg")), for: target)
        let successes = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, fit: .contain, onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value > 0 })

        MediaStage.assertGolden(window, named: "image_svg_contain")
    }

    @Test("shows the authored blur while the vector is on its way", .tags(.golden))
    func blurWhileVectorLoads() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("badge-held.svg")
        MediaOrigin.set(.status(200, try testkitAsset("testkit-badge.svg")), for: target, held: true)
        let recorder = HealthRecorder()

        let window = MediaStage.image(url: target.absoluteString, fit: .contain, blurHash: Self.blurHash)
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })

        #expect(recorder.all.isEmpty)
        MediaStage.assertGolden(window, named: "image_svg_blur_loading")
        MediaOrigin.release(target)
    }

    @Test("a missing vector reports http_4xx once and shows the blur", .tags(.golden))
    func missingVectorReportsAndShowsBlur() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("never-uploaded.svg")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()
        let failures = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, fit: .contain, blurHash: Self.blurHash,
            onFailure: { failures.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .image, cause: "http_4xx")])
        #expect(failures.value == 1)
        MediaStage.assertGolden(window, named: "image_svg_missing")
    }

    @Test("a malformed vector reports decode once")
    func malformedVectorReportsDecode() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("broken.svg")
        MediaOrigin.set(.status(200, MediaFixtures.brokenSVG), for: target)
        let recorder = HealthRecorder()
        let failures = CallCount()

        let window = MediaStage.image(url: target.absoluteString, onFailure: { failures.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .image, cause: "decode")])
        #expect(failures.value == 1)
    }

    @Test("a vector is recognised by its .svg extension with a query string")
    func vectorWithQueryStringIsDrawn() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("signed.svg?sig=abc123&exp=1893456000")
        MediaOrigin.set(.status(200, try testkitAsset("testkit-badge.svg")), for: target)
        let recorder = HealthRecorder()
        let successes = CallCount()

        let window = MediaStage.image(url: target.absoluteString, onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(MediaOrigin.requests(for: target).count == 1)
        #expect(successes.value == 1)
        #expect(recorder.all.isEmpty)
    }

    @Test("a second render of the same vector makes no fetch")
    func secondVectorRenderIsCacheHit() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("badge-twice.svg")
        MediaOrigin.set(.status(200, try testkitAsset("testkit-badge.svg")), for: target)
        let firstSuccesses = CallCount()
        let secondSuccesses = CallCount()

        let first = MediaStage.image(url: target.absoluteString, onSuccess: { firstSuccesses.value += 1 })
        #expect(await waitUntilMedia { firstSuccesses.value > 0 })
        ComponentTestHost.unmount(first)

        let second = MediaStage.image(url: target.absoluteString, onSuccess: { secondSuccesses.value += 1 })
        defer { ComponentTestHost.unmount(second) }
        #expect(await waitUntilMedia { secondSuccesses.value > 0 })

        #expect(MediaOrigin.requests(for: target).count == 1)
    }

    @Test("a tint colours the vector", .tags(.golden))
    func tintColoursTheVector() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("badge-tinted.svg")
        MediaOrigin.set(.status(200, try testkitAsset("testkit-badge.svg")), for: target)
        let successes = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, fit: .contain, tintColor: MediaFixtures.tint, onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value > 0 })

        MediaStage.assertGolden(window, named: "image_svg_tinted")
    }

    @Test("a vector server error reports nothing")
    func vectorServerErrorReportsNothing() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("busy.svg")
        MediaOrigin.set(.status(503, Data("busy".utf8)), for: target)
        let recorder = HealthRecorder()
        let failures = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, blurHash: Self.blurHash, onFailure: { failures.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all.isEmpty)
    }
}
}
