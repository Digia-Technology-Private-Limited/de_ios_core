import AVFoundation
import AVKit
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage
@testable import DigiaVideoEngine

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

@MainActor
private final class MuteModel: ObservableObject {
    @Published var muted = true
}

private struct VolumeHost: View {
    @ObservedObject var model: MuteModel
    let url: String
    let key: String
    let volume: Float

    var body: some View {
        MediaVideo(url: url, muted: model.muted, volume: volume, autoplay: false, playerKey: key)
    }
}

@MainActor
private final class PlayModel: ObservableObject {
    @Published var autoplay = false
}

private struct AutoplayHost: View {
    @ObservedObject var model: PlayModel
    let url: String

    var body: some View {
        MediaVideo(url: url, autoplay: model.autoplay, playerKey: "autoplay")
    }
}

@MainActor
private final class UrlModel: ObservableObject {
    @Published var url: String
    init(_ url: String) { self.url = url }
}

private struct RailLikeHost: View {
    @ObservedObject var model: UrlModel
    let lost: CallCount

    var body: some View {
        // The rail does not wait in the pool's queue: an evicted card says so through `onLost`.
        MediaVideo(
            url: model.url, playerKey: "rail", poolPriority: .onScreen, onLost: { lost.value += 1 },
            waitsForPlayer: false)
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
        // Well before the delay: still only the backdrop (guards `Task.sleep(spinnerDelay)` in `open`).
        _ = await waitUntilMedia(timeout: 0.1) { false }
        #expect(!Self.lit(ComponentTestHost.settledImage(of: window)), "no spinner at 100 ms")
        _ = await waitUntilMedia(timeout: MediaVideo.defaultSpinnerDelay + 0.2) { false }

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

    // Guards the `.fileFailedToParse` case in `mediaFailureCause(playerItem:)`: random bytes in an
    // mp4 fail AVFoundation with -11829 (underlying OSStatus -12848), which used to be unmapped,
    // so a corrupt video showed the failed box and reported nothing. Local file and range cache.
    @Test("a corrupt mp4 reports decode once", arguments: ["file", "http"])
    func corruptMP4ReportsDecode(source: String) async throws {
        install()
        defer { MediaOrigin.end() }
        let bytes = Data((0..<8192).map { UInt8(truncatingIfNeeded: ($0 &* 2654435761) >> 7) })
        let url: String
        if source == "file" {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString).mp4")
            try bytes.write(to: file)
            url = file.absoluteString
        } else {
            let video = MediaOrigin.url("corrupt.mp4")
            MediaOrigin.set(.status(200, bytes), for: video)
            url = video.absoluteString
        }
        let recorder = HealthRecorder()
        let failures = CallCount()

        let window = MediaStage.mount(MediaVideo(url: url, onFailure: { failures.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        _ = await waitUntilMedia(timeout: 0.3) { false }

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .video, cause: "decode")])
        #expect(failures.value == 1)
    }

    // Guards the `mediaUsableURL` guard in `MediaVideoPlayback.open`: a blank or schemeless URL is
    // unusable, reported once as `invalid_url`, and never borrows a player or fetches.
    @Test("a blank or schemeless URL reports invalid_url and builds no player",
          arguments: ["", "   ", "media.example.test/clip.mp4"])
    func unusableURLReportsInvalidURL(url: String) async {
        install()
        defer { MediaOrigin.end() }
        let recorder = HealthRecorder()
        let failures = CallCount()
        let pool = MediaServices.current.videoPool

        let window = MediaStage.mount(MediaVideo(url: url, onFailure: { failures.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .video, cause: "invalid_url")])
        #expect(pool.livePlayerCount == 0)
        #expect(MediaOrigin.totalRequestCount() == 0)
    }

    // Guards `setPlaying(autoplay)` in `MediaVideoPlayback.open` and `.onChange(of: autoplay)` in
    // `MediaVideo.body`: a video authored not to play stays paused once loaded, and the flag turns
    // it on and off afterwards.
    @Test("autoplay off keeps a loaded video paused, and the flag then plays and pauses it")
    func autoplayFollowsTheFlag() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("autoplay.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let pool = MediaServices.current.videoPool
        let model = PlayModel()

        let window = MediaStage.mount(AutoplayHost(model: model, url: video.absoluteString))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { pool.heldPlayer(for: "autoplay")?.currentItem?.status == .readyToPlay })
        let player = try #require(pool.heldPlayer(for: "autoplay"))
        _ = await waitUntilMedia(timeout: 0.5) { player.rate > 0 }
        #expect(player.rate == 0, "authored not to play")

        model.autoplay = true
        #expect(await waitUntilMedia { player.rate > 0 })
        model.autoplay = false
        #expect(await waitUntilMedia { player.rate == 0 })
    }

    // Guards `MediaVideoPlayback.setAppActive`: going inactive pauses a playing video, and coming
    // back plays it only if it was playing; a user's pause and a non-opted-in surface are left alone.
    @Test("a video that pauses in the background resumes only what was playing")
    func backgroundPausesAndResumesWhatWasPlaying() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("background.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let pool = MediaServices.current.videoPool
        func resign() { NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil) }
        func become() { NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil) }

        let window = MediaStage.mount(MediaVideo(
            url: video.absoluteString, loop: true, pausesInBackground: true, playerKey: "background"))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { (pool.heldPlayer(for: "background")?.rate ?? 0) > 0 })
        let player = try #require(pool.heldPlayer(for: "background"))
        #expect(player.rate > 0)

        resign()
        #expect(await waitUntilMedia { player.rate == 0 }, "paused in the background")
        become()
        #expect(await waitUntilMedia { player.rate > 0 }, "plays again in the foreground")

        player.pause()  // the user's own pause
        resign()
        become()
        _ = await waitUntilMedia(timeout: 0.5) { player.rate > 0 }
        #expect(player.rate == 0, "a user's pause survives a trip to the background")
    }

    @Test("a video that does not opt in keeps playing in the background")
    func backgroundIsIgnoredWithoutOptIn() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("no-background.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let pool = MediaServices.current.videoPool

        let window = MediaStage.mount(MediaVideo(url: video.absoluteString, loop: true, playerKey: "no-background"))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { (pool.heldPlayer(for: "no-background")?.rate ?? 0) > 0 })
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        _ = await waitUntilMedia(timeout: 0.5) { pool.heldPlayer(for: "no-background")?.rate == 0 }
        #expect((pool.heldPlayer(for: "no-background")?.rate ?? 0) > 0)
    }

    // Guards the `startMs` seek in `MediaVideoPlayback.open` / `seekToStartIfReady`, and that a nil
    // `startMs` leaves the pool's playhead alone so a remount resumes.
    @Test("startMs puts the opened player at that position, and nil keeps the playhead")
    func startMsSeeksAndNilKeepsThePlayhead() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("start.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let pool = MediaServices.current.videoPool

        let first = MediaStage.mount(MediaVideo(
            url: video.absoluteString, autoplay: false, playerKey: "start", startMs: 3_000))
        #expect(await waitUntilMedia { (pool.heldPlayer(for: "start")?.currentTime().seconds ?? 0) > 2.9 })
        let player = try #require(pool.heldPlayer(for: "start"))
        #expect(abs(player.currentTime().seconds - 3) < 0.1, "at the authored start: \(player.currentTime().seconds)")
        ComponentTestHost.unmount(first)
        #expect(await waitUntilMedia { pool.heldPlayer(for: "start") == nil })

        let second = MediaStage.mount(MediaVideo(
            url: video.absoluteString, autoplay: false, playerKey: "start", startMs: nil))
        defer { ComponentTestHost.unmount(second) }
        #expect(await waitUntilMedia { pool.heldPlayer(for: "start") != nil })
        _ = await waitUntilMedia(timeout: 0.4) { false }

        #expect(pool.heldPlayer(for: "start") === player, "the same player came back")
        #expect(abs(player.currentTime().seconds - 3) < 0.1, "not moved: \(player.currentTime().seconds)")
    }

    // Guards `evicted()` in `MediaVideoPlayback`: a holder whose player the pool takes back for a
    // story page shows its still again (no player drawn) and says so once through `onLost`; it
    // borrows again when it next opens (here a URL change), not on its own.
    @Test("an evicted holder drops its player, calls onLost once and borrows again when it next opens")
    func evictedHolderLetsGoAndBorrowsAgain() async throws {
        install()
        defer { MediaOrigin.end() }
        let loader = MediaServices.current.videoLoader
        let pool = VideoPlayerPool(maxPlayers: 1, ceiling: 1, makeItem: { mediaVideoItem(for: $0, loader: loader) })
        MediaServices.override(videoPool: pool)
        let first = MediaOrigin.url("evict-a.mp4")
        let second = MediaOrigin.url("evict-b.mp4")
        let other = MediaOrigin.url("evict-other.mp4")
        for url in [first, second, other] { MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: url) }
        let lost = CallCount()
        let model = UrlModel(first.absoluteString)

        let window = MediaStage.mount(RailLikeHost(model: model, lost: lost))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { pool.heldPlayer(for: "rail") != nil })
        #expect(await waitUntilMedia { !Self.drawnPlayers(in: window).isEmpty }, "drawn while held")

        let taker = try #require(pool.borrow(key: "page", url: other, priority: .viewerPage))

        #expect(lost.value == 1)
        #expect(pool.heldPlayer(for: "rail") == nil)
        ComponentTestHost.drainRunLoop(for: 0.2)
        #expect(Self.drawnPlayers(in: window).isEmpty, "back to its still")
        #expect(lost.value == 1, "told once, and no borrow on its own")
        #expect(pool.heldKeys == ["page"])

        pool.giveBack(key: "page", player: taker, priority: .viewerPage)
        model.url = second.absoluteString
        #expect(await waitUntilMedia { pool.heldPlayer(for: "rail") != nil }, "borrowed again on its next open")
    }

    /// A pool with ceiling 1 reading through the fake origin, for every video the test draws.
    private func onePlayerPool() -> VideoPlayerPool {
        let loader = MediaServices.current.videoLoader
        let pool = VideoPlayerPool(maxPlayers: 1, ceiling: 1, makeItem: { mediaVideoItem(for: $0, loader: loader) })
        MediaServices.override(videoPool: pool)
        return pool
    }

    // Guards `releasePlayer()` in `MediaVideoPlayback.fail(cause:)` (OD-24): at a ceiling of one a
    // second video waits; when the first fails (a 404) the waiting one gets the player at once,
    // not when the failed one closes.
    @Test("a failed video gives its player to the waiting one")
    func failedVideoGivesItsPlayerToTheWaitingOne() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = onePlayerPool()
        let broken = MediaOrigin.url("fail-frees-broken.mp4")
        let waiting = MediaOrigin.url("fail-frees-waiting.mp4")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: broken, held: true)
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: waiting)
        let failures = CallCount()

        let first = MediaStage.mount(MediaVideo(
            url: broken.absoluteString, playerKey: "broken", onFailure: { failures.value += 1 }))
        defer { ComponentTestHost.unmount(first) }
        #expect(await waitUntilMedia { pool.heldPlayer(for: "broken") != nil })
        let second = MediaStage.mount(MediaVideo(url: waiting.absoluteString, playerKey: "waiting"))
        defer { ComponentTestHost.unmount(second) }
        #expect(await waitUntilMedia { pool.queuedKeys == ["waiting"] })

        MediaOrigin.release(broken)
        #expect(await waitUntilMedia { failures.value > 0 })

        #expect(await waitUntilMedia { pool.heldKeys == ["waiting"] }, "the waiting video took the failed one's player")
    }

    // Guards `self.wantsPlaying = playing` in `MediaVideoPlayback.watchRate(of:)` (decision 2b,
    // R1-10, R2-01): a video authored not to play that the user starts through the controls wants
    // to play. When Stage 1 takes its player it waits ahead of an older paused waiter, and it plays
    // when it gets a player back.
    @Test("a video the user started through the controls waits as playing and plays again after Stage 1")
    func userStartedPlayWaitsAsPlaying() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = onePlayerPool()
        let video = MediaOrigin.url("user-play.mp4")
        let page = MediaOrigin.url("user-play-page.mp4")
        for url in [video, page] { MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: url) }

        let window = MediaStage.mount(MediaVideo(url: video.absoluteString, autoplay: false, playerKey: "manual"))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { pool.heldPlayer(for: "manual")?.currentItem?.status == .readyToPlay })
        let player = try #require(pool.heldPlayer(for: "manual"))
        player.play() // the native controls' play button
        _ = await waitUntilMedia(timeout: 0.3) { false }
        let older = pool.wait(key: "older", url: page, priority: .onScreen, wantsPlay: false) {}
        defer { pool.cancelWait(older) }

        let taker = try #require(pool.borrow(key: "page", url: page, priority: .viewerPage))
        #expect(pool.queuedKeys == ["manual", "older"], "the user's video waits ahead of the paused one")

        pool.giveBack(key: "page", player: taker, priority: .viewerPage)
        #expect(await waitUntilMedia { (pool.heldPlayer(for: "manual")?.rate ?? 0) > 0 }, "back and playing")
    }

    // Guards `self.wantsPlaying = playing` in `MediaVideoPlayback.watchRate(of:)` (decision 2b,
    // R1-10, R2-01): an autoplay video the user paused through the controls does not want to play.
    // When Stage 1 takes its player it waits behind a waiter that wants to play, and it stays
    // paused when it gets a player back.
    @Test("an autoplay video the user paused waits as paused and stays paused after Stage 1")
    func userPausedAutoplayWaitsAsPaused() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = onePlayerPool()
        let video = MediaOrigin.url("user-pause.mp4")
        let page = MediaOrigin.url("user-pause-page.mp4")
        for url in [video, page] { MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: url) }

        let window = MediaStage.mount(MediaVideo(url: video.absoluteString, autoplay: true, playerKey: "paused"))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { (pool.heldPlayer(for: "paused")?.rate ?? 0) > 0 })
        let player = try #require(pool.heldPlayer(for: "paused"))
        player.pause() // the native controls' pause button
        _ = await waitUntilMedia(timeout: 0.3) { false }
        let newer = pool.wait(key: "newer", url: page, priority: .onScreen, wantsPlay: true) {}

        let taker = try #require(pool.borrow(key: "page", url: page, priority: .viewerPage))
        #expect(pool.queuedKeys == ["newer", "paused"], "the paused video waits behind one that wants to play")

        pool.cancelWait(newer)
        pool.giveBack(key: "page", player: taker, priority: .viewerPage)
        #expect(await waitUntilMedia { pool.heldPlayer(for: "paused")?.currentItem?.status == .readyToPlay })
        _ = await waitUntilMedia(timeout: 0.5) { (pool.heldPlayer(for: "paused")?.rate ?? 0) > 0 }
        #expect(pool.heldPlayer(for: "paused")?.rate == 0, "back, and still paused")
    }

    // Guards the at-end check in `MediaVideoPlayback.watchRate(of:)` (R2-02): the rate drops to 0
    // when a video reaches its end, and that is not a pause. An ended autoplay video still wants to
    // play, so when Stage 1 takes its player it waits ahead of an older paused waiter.
    @Test("an autoplay video that reached its end waits as playing when Stage 1 takes its player")
    func endedAutoplayWaitsAsPlaying() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = onePlayerPool()
        let video = MediaOrigin.url("ended.mp4")
        let page = MediaOrigin.url("ended-page.mp4")
        for url in [video, page] { MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: url) }

        // movie.mp4 is 12.6 s: from 11.8 s it ends in under a second.
        let window = MediaStage.mount(MediaVideo(
            url: video.absoluteString, autoplay: true, playerKey: "ended", startMs: 11_800))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { (pool.heldPlayer(for: "ended")?.rate ?? 0) > 0 })
        let player = try #require(pool.heldPlayer(for: "ended"))
        #expect(await waitUntilMedia { player.rate == 0 && VideoPlayerPool.isFinished(player) }, "played to its end")
        _ = await waitUntilMedia(timeout: 0.3) { false }
        let older = pool.wait(key: "older", url: page, priority: .onScreen, wantsPlay: false) {}
        defer { pool.cancelWait(older) }

        let taker = try #require(pool.borrow(key: "page", url: page, priority: .viewerPage))
        defer { pool.giveBack(key: "page", player: taker, priority: .viewerPage) }

        #expect(pool.queuedKeys == ["ended", "older"], "the ended video still wants to play")
    }

    // Guards `evictedResume` in `VideoPlayerPool` (`take(_:of:)` keeps the playhead, `borrow` hands
    // it to the next holder of the key) and `takeResumeMs` in `MediaVideoPlayback.attemptBorrow`
    // (decision 2a, R1-16): a video whose player Stage 1 took gets one back through the queue when
    // the viewer gives back, and plays on from where it was, not from 0.
    @Test("a video Stage 1 took resumes where it was when it gets a player back")
    func stageOneEvictedVideoResumes() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = onePlayerPool()
        let video = MediaOrigin.url("resume.mp4")
        let page = MediaOrigin.url("resume-page.mp4")
        for url in [video, page] { MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: url) }

        let window = MediaStage.mount(MediaVideo(url: video.absoluteString, autoplay: true, playerKey: "resume"))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { (pool.heldPlayer(for: "resume")?.currentTime().seconds ?? 0) >= 2 })
        let playhead = try #require(pool.heldPlayer(for: "resume")).currentTime().seconds

        let taker = try #require(pool.borrow(key: "page", url: page, priority: .viewerPage))
        #expect(pool.queuedKeys == ["resume"])
        pool.giveBack(key: "page", player: taker, priority: .viewerPage)

        // From 0 it would need more than 2 s of playback to get there.
        #expect(await waitUntilMedia(timeout: 1.5) {
            (pool.heldPlayer(for: "resume")?.currentTime().seconds ?? 0) >= playhead - 0.25
        }, "resumed near \(playhead) s")
    }

    // Guards `player.volume = volume` in `MediaVideoPlayback.open` (W8-03; Flutter Y8-02, Android
    // `configuredVolume...`): the authored level is on the player from the start, independent of
    // mute, so unmuting gives that level and not the player's default 1. Also when the player is a
    // freed one that last played at another level: a holder reusing it must not inherit that level.
    @Test("the authored volume is the level after unmute, also on a reused player")
    func authoredVolumeSurvivesUnmute() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("volume.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let pool = MediaServices.current.videoPool
        let model = MuteModel()

        let window = MediaStage.mount(VolumeHost(model: model, url: video.absoluteString, key: "pip", volume: 0.5))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { pool.heldPlayer(for: "pip") != nil })
        let player = try #require(pool.heldPlayer(for: "pip"))
        #expect(player.isMuted)
        #expect(player.volume == 0.5, "set while muted")

        model.muted = false
        #expect(await waitUntilMedia { !player.isMuted })
        #expect(player.volume == 0.5, "audible at the authored level")

        // A freed player that last played at 0.8 is taken over by a new holder authored at 0.25.
        let reuse = MediaOrigin.url("volume-reuse.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: reuse)
        let url = try #require(URL(string: reuse.absoluteString))
        let freed = try #require(pool.borrow(key: "story", url: url, priority: .onScreen))
        freed.volume = 0.8
        pool.giveBack(key: "story", player: freed, priority: .onScreen)

        let second = MediaStage.mount(VolumeHost(model: MuteModel(), url: reuse.absoluteString, key: "pip-2", volume: 0.25))
        defer { ComponentTestHost.unmount(second) }
        #expect(await waitUntilMedia { pool.heldPlayer(for: "pip-2") != nil })

        #expect(pool.heldPlayer(for: "pip-2") === freed, "the freed player was reused")
        #expect(freed.volume == 0.25)
    }

    /// The players the window's layers draw.
    private static func drawnPlayers(in view: UIView) -> [AVPlayer] {
        let own = (view.layer as? AVPlayerLayer)?.player.map { [$0] } ?? []
        return own + view.subviews.flatMap { drawnPlayers(in: $0) }
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
