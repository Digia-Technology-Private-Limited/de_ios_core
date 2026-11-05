import Foundation
import SDWebImage
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// Raster pictures through `MediaImage` over the fake origin: how a picture is drawn (blur,
// transparency, fit, tint), where it comes from (memory, disk, network), and what a failure
// reports. Every picture is drawn on the one `MediaStage`; what is on screen is proved by the
// goldens, and the other tests assert callbacks, request logs and health records.

extension RenderedUITests {
@MainActor
@Suite("MediaImage pictures", .serialized, .tags(.media, .component))
struct MediaImagePictureTests {
    private static let blurHash = MediaFixtures.blurHash

    /// A wrapper whose URL a test can switch and whose surface a test can redraw.
    private struct Host: View {
        @ObservedObject var model: MediaModel
        var blurHash: String?
        var onSuccess: (() -> Void)?
        var onFailure: (() -> Void)?

        var body: some View {
            let _ = model.redraws
            MediaImage(url: model.url, blurHash: blurHash, onSuccess: onSuccess, onFailure: onFailure)
        }
    }

    @Test("an undecodable blur string shows nothing while loading and does not crash", .tags(.golden))
    func undecodableBlurShowsNothing() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("held-bad-blur.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target, held: true)
        let recorder = HealthRecorder()

        let window = MediaStage.image(url: target.absoluteString, blurHash: "!!! not a blurhash !!!")
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })

        #expect(recorder.all.isEmpty)
        MediaStage.assertGolden(window, named: "image_bad_blurhash_loading")
        MediaOrigin.release(target)
    }

    @Test("a transparent picture shows the page through it, not the blur", .tags(.golden))
    func transparentPictureShowsThePage() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("ring.png")
        MediaOrigin.set(.status(200, MediaFixtures.transparentRingPNG()), for: target)
        let successes = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, fit: .contain, blurHash: Self.blurHash,
            onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value > 0 })

        MediaStage.assertGolden(window, named: "image_transparent_loaded")
    }

    @Test("cover fills the box and crops the picture", .tags(.golden))
    func coverFillsTheBox() async {
        await drawQuadrants(fit: .cover, golden: "image_fit_cover")
    }

    @Test("contain fits the whole picture inside the box", .tags(.golden))
    func containFitsInsideTheBox() async {
        await drawQuadrants(fit: .contain, golden: "image_fit_contain")
    }

    @Test("fill stretches the picture to the box", .tags(.golden))
    func fillStretchesToTheBox() async {
        await drawQuadrants(fit: .fill, golden: "image_fit_fill")
    }

    private func drawQuadrants(
        fit: MediaFit = .cover, focalX: CGFloat = 0.5, focalY: CGFloat = 0.5, zoom: CGFloat = 1,
        golden: String
    ) async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("quadrants-\(fit.rawValue).png")
        MediaOrigin.set(.status(200, MediaFixtures.quadrantPNG()), for: target)
        let successes = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, fit: fit, focalX: focalX, focalY: focalY, zoom: zoom,
            onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value > 0 })

        MediaStage.assertGolden(window, named: golden)
    }

    @Test("a focal point at the top start shows the top start of a cropped picture", .tags(.golden))
    func focalTopStartShowsTheTopStart() async {
        await drawQuadrants(focalX: 0, focalY: 0, golden: "image_focal_top_start")
    }

    @Test("a focal point at the bottom end shows the bottom end of a cropped picture", .tags(.golden))
    func focalBottomEndShowsTheBottomEnd() async {
        await drawQuadrants(focalX: 1, focalY: 1, golden: "image_focal_bottom_end")
    }

    @Test("zoom 2 magnifies the picture around the centre", .tags(.golden))
    func zoomInMagnifiesAroundTheCentre() async {
        await drawQuadrants(zoom: 2, golden: "image_zoom_in")
    }

    @Test("zoom 2 magnifies around the focal point, not the centre", .tags(.golden))
    func zoomInMagnifiesAroundTheFocalPoint() async {
        await drawQuadrants(focalX: 0.1, focalY: 0.9, zoom: 2, golden: "image_zoom_in_corner")
    }

    @Test("zoom 0.5 shrinks the picture and shows the page around it", .tags(.golden))
    func zoomOutShowsThePageAroundThePicture() async {
        await drawQuadrants(zoom: 0.5, golden: "image_zoom_out")
    }

    @Test("a focal point or zoom out of range, or not a number, draws like the nearest valid one")
    func badFocalAndZoomDegrade() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("quadrants-bad-focal.png")
        MediaOrigin.set(.status(200, MediaFixtures.quadrantPNG()), for: target)

        func render(focalX: CGFloat, focalY: CGFloat, zoom: CGFloat) async -> Data? {
            let successes = CallCount()
            let window = MediaStage.image(
                url: target.absoluteString, focalX: focalX, focalY: focalY, zoom: zoom,
                onSuccess: { successes.value += 1 })
            defer { ComponentTestHost.unmount(window) }
            guard await waitUntilMedia(condition: { successes.value > 0 }) else { return nil }
            ComponentTestHost.drainRunLoop(for: 0.3)
            return ComponentTestHost.settledImage(of: window).pngData()
        }

        let nearest = await render(focalX: 1, focalY: 0, zoom: 10)
        #expect(nearest != nil)
        #expect(await render(focalX: 7, focalY: -3, zoom: 100) == nearest)
        let centred = await render(focalX: 0.5, focalY: 0.5, zoom: 1)
        #expect(await render(focalX: .nan, focalY: .infinity, zoom: .nan) == centred)
        #expect(nearest != centred)
    }

    @Test("a tint colours the picture and not the blur", .tags(.golden))
    func tintColoursThePictureOnly() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("tint-star-icon.png")
        MediaOrigin.set(.status(200, try testkitAsset("tint-star-icon.png")), for: target, held: true)
        let successes = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, fit: .contain, blurHash: Self.blurHash, tintColor: .red,
            onSuccess: { successes.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })
        MediaStage.assertGolden(window, named: "image_tinted_blur_loading")

        MediaOrigin.release(target)
        #expect(await waitUntilMedia { successes.value > 0 })
        MediaStage.assertGolden(window, named: "image_tinted")
    }

    @Test("a picture on disk loads with no fetch after the memory cache is cleared")
    func diskCacheServesAfterMemoryCleared() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("on-disk.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target)
        let key = SDWebImageManager.shared.cacheKey(for: target)
        defer {
            SDImageCache.shared.removeImageFromMemory(forKey: key)
            SDImageCache.shared.removeImageFromDisk(forKey: key)
        }
        let firstSuccesses = CallCount()
        let secondSuccesses = CallCount()

        let first = MediaStage.image(url: target.absoluteString, onSuccess: { firstSuccesses.value += 1 })
        #expect(await waitUntilMedia { firstSuccesses.value > 0 })
        ComponentTestHost.unmount(first)
        #expect(await waitUntilMedia { SDImageCache.shared.diskImageDataExists(withKey: key) })
        SDImageCache.shared.removeImageFromMemory(forKey: key)
        #expect(SDImageCache.shared.imageFromMemoryCache(forKey: key) == nil)

        let second = MediaStage.image(url: target.absoluteString, onSuccess: { secondSuccesses.value += 1 })
        defer { ComponentTestHost.unmount(second) }
        #expect(await waitUntilMedia { secondSuccesses.value > 0 })

        #expect(MediaOrigin.requests(for: target).count == 1)
    }

    @Test("a page that is not a picture (HTML served as 200) reports decode once")
    func pageInsteadOfPictureReportsDecode() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("sign-in.png")
        MediaOrigin.set(.status(200, MediaFixtures.htmlPage), for: target)
        let recorder = HealthRecorder()
        let failures = CallCount()

        let window = MediaStage.image(url: target.absoluteString, onFailure: { failures.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .image, cause: "decode")])
        #expect(failures.value == 1)
    }

    @Test("a blank url shows the error placeholder", .tags(.golden))
    func blankURLShowsPlaceholder() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let failures = CallCount()

        let window = MediaStage.image(url: "", blurHash: Self.blurHash, onFailure: { failures.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })

        MediaStage.assertGolden(window, named: "image_blank_url")
    }

    @Test("switching the url drops the old picture and shows the new one's loading state", .tags(.golden))
    func switchingURLShowsTheNewLoadingState() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let first = MediaOrigin.url("first.png")
        let second = MediaOrigin.url("second.png")
        MediaOrigin.set(.status(200, MediaFixtures.quadrantPNG()), for: first)
        MediaOrigin.set(.status(200, solidPNG(.red)), for: second, held: true)
        let model = MediaModel(url: first.absoluteString)
        let successes = CallCount()

        let window = MediaStage.mount(
            Host(model: model, blurHash: Self.blurHash, onSuccess: { successes.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value == 1 })

        model.url = second.absoluteString
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: second).isEmpty })
        MediaStage.assertGolden(window, named: "image_url_switch_loading")

        MediaOrigin.release(second)
        #expect(await waitUntilMedia { successes.value == 2 })
    }

    @Test("a failure is reported once, not again when the surface redraws (a 404)")
    func notFoundIsNotReportedAgainOnRedraw() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("gone.png")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()
        let failures = CallCount()
        let model = MediaModel(url: target.absoluteString)

        let window = MediaStage.mount(
            Host(model: model, blurHash: Self.blurHash, onFailure: { failures.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        for _ in 0..<5 {
            model.redraw()
            ComponentTestHost.drainRunLoop(for: 0.1)
        }

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .image, cause: "http_4xx")])
        #expect(failures.value == 1)
        #expect(MediaOrigin.requests(for: target).count == 1)
    }

    @Test("a failure is reported once, not again when the surface redraws (an unusable url)")
    func unusableURLIsNotReportedAgainOnRedraw() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let recorder = HealthRecorder()
        let failures = CallCount()
        let model = MediaModel(url: "")

        let window = MediaStage.mount(
            Host(model: model, blurHash: Self.blurHash, onFailure: { failures.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        for _ in 0..<5 {
            model.redraw()
            ComponentTestHost.drainRunLoop(for: 0.1)
        }

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .image, cause: "invalid_url")])
        #expect(failures.value == 1)
    }

    @Test("health carries the campaign key of the surface that drew it", arguments: [
        "campaign-a", "campaign-b",
    ])
    func healthCarriesTheSurfaceCampaign(campaign: String) async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("gone-\(campaign).png")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()

        let window = MediaStage.mount(
            MediaImage(url: target.absoluteString).environment(\.digiaCampaignKey, campaign))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })

        #expect(recorder.all == [.init(campaignKey: campaign, kind: .image, cause: "http_4xx")])
    }
}
}
