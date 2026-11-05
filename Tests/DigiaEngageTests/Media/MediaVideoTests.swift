import AVFoundation
import AVKit
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// `MediaVideo` over the fake origin: the video item reads through the real range cache, whose
// session is routed to `MediaOrigin`. What is on screen before the first frame is proved by the
// goldens; the other tests assert callbacks and health records.

@Suite("MediaVideo rules", .tags(.media, .unit))
struct MediaVideoRuleTests {
    // Guards the branch order in `MediaVideoStill.init` (Q1) and `MediaVideoStill.canShow`,
    // which decides the spinner (R1-17: the same rule on every stack).
    @Test("the still is the thumbnail, else the BlurHash, else the dark backdrop")
    func stillOrder() {
        #expect(MediaVideoStill(thumbnailUrl: "https://a.test/t.jpg", blurHash: "LEHV") == .thumbnail("https://a.test/t.jpg"))
        #expect(MediaVideoStill(thumbnailUrl: "  ", blurHash: "LEHV") == .blurHash("LEHV"))
        #expect(MediaVideoStill(thumbnailUrl: nil, blurHash: "") == .backdrop)
        // An unusable thumbnail still goes to MediaImage (which reports it); only the BlurHash
        // can show, so with none the spinner is allowed.
        #expect(MediaVideoStill(thumbnailUrl: "{{thumb}}", blurHash: nil) == .thumbnail("{{thumb}}"))
        #expect(!MediaVideoStill.canShow(thumbnailUrl: "{{thumb}}", blurHash: nil))
        #expect(MediaVideoStill.canShow(thumbnailUrl: "{{thumb}}", blurHash: "LEHV"))
        #expect(MediaVideoStill.canShow(thumbnailUrl: "https://a.test/t.jpg", blurHash: nil))
    }

    // N1: the layer fits relative to its own bounds; guards `MediaFit.videoGravity`.
    @Test("each fit mode maps to its layer gravity")
    func fitPerMode() {
        #expect(MediaFit.cover.videoGravity == .resizeAspectFill)
        #expect(MediaFit.contain.videoGravity == .resizeAspect)
        #expect(MediaFit.fill.videoGravity == .resize)
    }

    // R7-03: guards the CoreMedia -12938 line in `mediaCacheHTTPStatus`. The error shapes are the
    // ones a simulator run logged for a stream playlist answered 404 and 500 (the error log was empty).
    @Test("a stream playlist's 404 reports http_4xx and its 5xx reports nothing")
    func streamNotFoundIsHttp4xx() {
        func itemError(_ urlCode: Int, _ coreMediaCode: Int) -> NSError {
            NSError(domain: NSURLErrorDomain, code: urlCode, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: coreMediaCode),
            ])
        }
        #expect(mediaCacheHTTPStatus(in: itemError(-1100, -12938)) == 404)
        #expect(mediaFailureCause(httpStatus: mediaCacheHTTPStatus(in: itemError(-1100, -12938))) == "http_4xx")
        #expect(mediaCacheHTTPStatus(in: itemError(-1008, -16847)) == nil)
    }
}

extension RenderedUITests {
@MainActor
@Suite("MediaVideo wrapper", .serialized, .tags(.media, .component))
struct MediaVideoComponentTests {
    private static let blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    private static let backdrop = UIColor(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255, alpha: 1)

    private func install() {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
    }

    @Test("shows the thumbnail until the first frame", .tags(.golden))
    func thumbnailWhileLoading() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("held-thumb.mp4")
        let thumbnail = MediaOrigin.url("tint-star-icon.png")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)
        MediaOrigin.set(.status(200, try testkitAsset("tint-star-icon.png")), for: thumbnail)

        let window = MediaStage.mount(MediaVideo(
            url: video.absoluteString, fit: .contain, thumbnailUrl: thumbnail.absoluteString,
            blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty && !MediaOrigin.requests(for: thumbnail).isEmpty })
        // The thumbnail decodes after its request: wait until the black star covers the box's centre.
        #expect(await waitUntilMedia {
            let image = ComponentTestHost.settledImage(of: window)
            return pixelColor(
                of: image, atX: Int(image.size.width / 2 * image.scale), y: Int(image.size.height / 2 * image.scale)
            ).map { colorsNearly($0, .black) } ?? false
        })

        MediaStage.assertGolden(window, named: "video_thumbnail_loading")
        MediaOrigin.release(video)
    }

    @Test("shows the BlurHash and no spinner until the first frame", .tags(.golden))
    func blurHashWhileLoading() async {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("held-blur.mp4")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)

        let window = MediaStage.mount(MediaVideo(url: video.absoluteString, blurHash: Self.blurHash))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty })
        _ = await waitUntilMedia(timeout: MediaVideo.defaultSpinnerDelay + 0.3) { false }

        MediaStage.assertGolden(window, named: "video_blur_loading")
        MediaOrigin.release(video)
    }

    @Test("shows the dark backdrop before the spinner delay", .tags(.golden))
    func darkBeforeSpinner() async {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("held-dark.mp4")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)

        let window = MediaStage.mount(MediaVideo(url: video.absoluteString, spinnerDelay: 60))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty })

        MediaStage.assertGolden(window, named: "video_dark_loading")
        MediaOrigin.release(video)
    }

    @Test("the spinner appears only after 400 ms with nothing to show")
    func spinnerAfterDelay() async {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("held-spinner.mp4")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)

        let window = MediaStage.mount(MediaVideo(url: video.absoluteString))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty })
        _ = await waitUntilMedia(timeout: MediaVideo.defaultSpinnerDelay + 0.3) { false }

        // The spinner animates, so its frame can't be a golden: the proof is that something
        // lighter than the backdrop is drawn in the box (the dark test proves the box is the backdrop).
        let image = ComponentTestHost.settledImage(of: window)
        let scale = image.scale
        let box = CGRect(
            x: (image.size.width - MediaStage.size.width) / 2, y: (image.size.height - MediaStage.size.height) / 2,
            width: MediaStage.size.width, height: MediaStage.size.height)
        let lit = stride(from: box.minX + 4, to: box.maxX - 4, by: 2).contains { x in
            stride(from: box.minY + 4, to: box.maxY - 4, by: 2).contains { y in
                pixelColor(of: image, atX: Int(x * scale), y: Int(y * scale)).map { !colorsNearly($0, Self.backdrop, tolerance: 0.2) } ?? false
            }
        }
        #expect(lit)
        MediaOrigin.release(video)
    }

    @Test("a video that was never uploaded shows the failed box and reports http_4xx", .tags(.golden))
    func notFoundReportsHttp4xx() async {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("never-uploaded.mp4")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: video)
        let recorder = HealthRecorder()
        let failures = CallCount()

        let window = MediaStage.mount(MediaVideo(url: video.absoluteString, onFailure: { failures.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .video, cause: "http_4xx")])
        MediaStage.assertGolden(window, named: "video_failed")
    }

    @Test("a network failure shows the failed box and reports nothing")
    func networkFailureReportsNothing() async {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("offline.mp4")
        MediaOrigin.set(.fail(.notConnectedToInternet), for: video)
        let recorder = HealthRecorder()
        let failures = CallCount()

        let window = MediaStage.mount(MediaVideo(url: video.absoluteString, onFailure: { failures.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })

        #expect(recorder.all.isEmpty)
    }

    @Test("an unresolved URL reports invalid_url without fetching")
    func unresolvedURLReportsInvalidURL() async {
        install()
        defer { MediaOrigin.end() }
        let recorder = HealthRecorder()
        let failures = CallCount()

        let window = MediaStage.mount(MediaVideo(url: "{{video}}", onFailure: { failures.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .video, cause: "invalid_url")])
        #expect(MediaOrigin.totalRequestCount() == 0)
    }

    // Guards the `MediaImage` branch for a non-blank thumbnail and `canShow` in `MediaVideo.open`.
    @Test("an unusable thumbnail is reported and does not hold back the spinner")
    func unusableThumbnailReportsAndAllowsSpinner() async {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("held-bad-thumb.mp4")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)
        let recorder = HealthRecorder()

        let window = MediaStage.mount(MediaVideo(url: video.absoluteString, thumbnailUrl: "{{thumb}}"))
        defer { ComponentTestHost.unmount(window) }
        _ = await waitUntilMedia(timeout: MediaVideo.defaultSpinnerDelay + 0.3) { false }

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .image, cause: "invalid_url")])
        #expect(Self.lit(ComponentTestHost.settledImage(of: window)))
        MediaOrigin.release(video)
    }

    // Guards the `showControls` branch in `MediaVideo.playerView` (OD-6).
    @Test("controls show only when showControls is on")
    func controlsOnlyWhenOn() async {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("held-controls.mp4")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)

        let plain = MediaStage.mount(MediaVideo(url: video.absoluteString))
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty })
        #expect(Self.playerControllers(in: plain.rootViewController).isEmpty)
        ComponentTestHost.unmount(plain)

        let controlled = MediaStage.mount(MediaVideo(url: video.absoluteString, showControls: true))
        defer { ComponentTestHost.unmount(controlled) }
        #expect(await waitUntilMedia { !Self.playerControllers(in: controlled.rootViewController).isEmpty })
        #expect(Self.playerControllers(in: controlled.rootViewController).allSatisfy { $0.showsPlaybackControls })
        MediaOrigin.release(video)
    }

    private static func playerControllers(in controller: UIViewController?) -> [AVPlayerViewController] {
        guard let controller else { return [] }
        let own = (controller as? AVPlayerViewController).map { [$0] } ?? []
        return own + controller.children.flatMap { playerControllers(in: $0) }
    }

    /// Whether something lighter than the backdrop is drawn in the stage box.
    private static func lit(_ image: UIImage) -> Bool {
        let scale = image.scale
        let box = CGRect(
            x: (image.size.width - MediaStage.size.width) / 2, y: (image.size.height - MediaStage.size.height) / 2,
            width: MediaStage.size.width, height: MediaStage.size.height)
        return stride(from: box.minX + 4, to: box.maxX - 4, by: 2).contains { x in
            stride(from: box.minY + 4, to: box.maxY - 4, by: 2).contains { y in
                pixelColor(of: image, atX: Int(x * scale), y: Int(y * scale)).map { !colorsNearly($0, backdrop, tolerance: 0.2) } ?? false
            }
        }
    }
}
}
