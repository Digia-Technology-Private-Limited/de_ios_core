import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The story rules (T8) that need a page on screen: a video page plays through `MediaVideo` with
// its spinner rule (T2), a failed video page shows its still and reports health (never the "Video
// failed" box), and the viewer recomputes its window when the slow-network verdict flips. Over the
// media suites' fake origin and stage.

/// A slow-network source a test flips.
private final class FlippableSlowNetwork: SlowNetworkSource, @unchecked Sendable {
    private let lock = NSLock()
    private var slow = false
    var isSlow: Bool {
        get { lock.withLock { slow } }
        set { lock.withLock { slow = newValue } }
    }
}

@MainActor
private final class SilentReporter: StoryViewerReporter {
    func onCompleted(total: Int, timeToCompleteMs: Int64) {}
    func onDismissed(index: Int) {}
}

extension RenderedUITests {
@MainActor
@Suite("Story pages", .serialized, .tags(.inline, .media, .component))
struct StoryPageTests {
    private static let backdrop = UIColor(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255, alpha: 1)

    private func install() {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
    }

    private func page(_ item: StoryItemConfig, onFailure: @escaping () -> Void = {}) -> VideoStoryPage {
        VideoStoryPage(
            item: item, pageKey: "page-\(UUID().uuidString)", muted: true, playing: true, startMs: 0,
            onReady: { _ in }, onEnded: {}, onFailure: onFailure, onLost: {})
    }

    // Guards `item.thumbnail != nil` in the still overlay of `StoryVideoSurface`: with no
    // thumbnail nothing covers `MediaVideo`, so its spinner shows once 400 ms pass with no frame.
    @Test("a video page with nothing to show draws the spinner once the delay passes")
    func videoPageSpinner() async {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("story-held.mp4")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)

        let window = MediaStage.mount(page(StoryItemConfig(type: .video, url: video.absoluteString, duration: nil)))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty })
        _ = await waitUntilMedia(timeout: MediaVideo.defaultSpinnerDelay + 0.3) { false }

        #expect(Self.lit(ComponentTestHost.settledImage(of: window)))
        MediaOrigin.release(video)
    }

    // Guards `failed ||` in the still overlay of `StoryVideoSurface`, which covers `MediaVideo`'s
    // failed box.
    @Test("a video page that cannot load shows its still and reports health, not the failed box")
    func failedVideoPageShowsItsStill() async {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("story-missing.mp4")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: video)
        let recorder = HealthRecorder()
        let failures = CallCount()

        let item = StoryItemConfig(type: .video, url: video.absoluteString, duration: nil)
        let window = MediaStage.mount(page(item, onFailure: { failures.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: .video, cause: "http_4xx")])
        #expect(!Self.lit(ComponentTestHost.settledImage(of: window)), "the dark still, no failed box")
    }

    // Guards `if slowSource().isSlow != plannedSlow { drivePlan() }` in `StoryViewer.tick`.
    @Test("the viewer recomputes its window when the network turns slow")
    func slowFlipRecomputesThePlan() async {
        var services = MediaServices.current
        let pool = VideoPlayerPool(maxPlayers: 4, makeItem: { AVPlayerItem(url: $0) })
        services.videoPool = pool
        let slow = FlippableSlowNetwork()
        let stories = [
            StoryItemConfig(type: .image, url: "https://story-slow.test/0.jpg", duration: 60_000),
            StoryItemConfig(type: .video, url: "https://story-slow.test/1.mp4", duration: nil),
            StoryItemConfig(type: .video, url: "https://story-slow.test/2.mp4", duration: nil),
        ]
        let viewer = StoryViewer(entry: StoryViewerEntry(
            stories: stories, startIndex: 0, restartOnCompleted: false, startMuted: true,
            defaultDurationMs: 5_000, reporter: SilentReporter(), onDismiss: {}
        )) { _ in EmptyView() }
            .environment(\.mediaServices, services)
            .environment(\.storySlowNetwork, slow)

        let window = MediaStage.mount(viewer)
        defer { ComponentTestHost.unmount(window) }
        let next = storyPoolKey(namespace: MediaStage.campaign, index: 1)
        #expect(await waitUntilMedia(timeout: 2) { pool.heldKeys.contains(next) }, "fast: the next video's player is held")

        slow.isSlow = true

        #expect(await waitUntilMedia(timeout: 2) { !pool.heldKeys.contains(next) }, "slow: only its first bytes are planned")
    }

    private func viewer(_ stories: [StoryItemConfig], handover: StoryHandover? = nil) -> some View {
        StoryViewer(entry: StoryViewerEntry(
            stories: stories, startIndex: 0, handover: handover, restartOnCompleted: false, startMuted: true,
            defaultDurationMs: 5_000, reporter: SilentReporter(), onDismiss: {}
        )) { _ in EmptyView() }
    }

    // Guards the `StoryVideoSurface(... priority: .railThumb ...)` in `StoryThumbnailVideo` (T3): a
    // rail video tile plays through `MediaVideo`, on the pool, at the thumbnail rank.
    @Test("a rail video tile plays through MediaVideo on the pool at the thumbnail rank")
    func railTileRoutesThroughMediaVideoOnThePool() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("rail-tile.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let pool = MediaServices.current.videoPool
        let item = StoryItemConfig(type: .video, url: video.absoluteString, duration: nil)

        let window = MediaStage.mount(StoryRail(
            items: [item], mode: .simultaneous, cardWidth: 120, cardHeight: 120, cardCornerRadius: 8,
            cardSpacing: 8, overlayOpen: false, onOpen: { _, _ in }))
        defer { ComponentTestHost.unmount(window) }

        let key = storyPoolKey(namespace: MediaStage.campaign, index: 0)
        #expect(await waitUntilMedia { pool.priority(of: key) == .railThumb })
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty }, "read through the range cache")
    }

    // Guards `keepPlayersFor: firstFrameShown ? [] : [index - 1, index + 1]` in
    // `StoryViewer.drivePlan` (V8-04): after a swipe on, until the new page's first frame, the page
    // just left keeps its player (a swipe back resumes it, N9), though the plan names only the new one.
    @Test("the viewer keeps the page just left's player until the new page's first frame")
    func viewerKeepsTheLeftPlayerUntilTheFirstFrame() async throws {
        install()
        defer { MediaOrigin.end() }
        let first = MediaOrigin.url("keep-first.mp4")
        let second = MediaOrigin.url("keep-second.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: first)
        MediaOrigin.set(.status(200, Data()), for: second, held: true)
        let pool = MediaServices.current.videoPool
        let stories = [first, second, second].map { StoryItemConfig(type: .video, url: $0.absoluteString, duration: nil) }

        let window = MediaStage.mount(viewer(stories))
        defer { ComponentTestHost.unmount(window) }
        let keyFirst = storyPoolKey(namespace: MediaStage.campaign, index: 0)
        let keySecond = storyPoolKey(namespace: MediaStage.campaign, index: 1)
        #expect(await waitUntilMedia { pool.heldPlayer(for: keySecond) != nil }, "page 0 showed its first frame, so page 1 is held")
        let player = try #require(pool.heldPlayer(for: keyFirst))
        let duration = try #require(player.currentItem?.duration.seconds)
        await player.seek(to: CMTime(seconds: duration - 0.4, preferredTimescale: 600))

        // Page 0's video ends and the viewer moves to page 1, whose video never shows a frame.
        #expect(await waitUntilMedia { pool.priority(of: keySecond) == .onScreen }, "the viewer moved on")
        ComponentTestHost.drainRunLoop(for: 0.2)

        #expect(pool.heldPlayer(for: keyFirst) === player, "page 0's player is kept for a swipe back")
        #expect(pool.heldPlayer(for: keySecond) != nil)
    }

    // Guards `playback.firstFrameShown ? groundAfterFirstFrame : mediaVideoBackdrop` in
    // `MediaVideo.body` as a handed-over player reaches it (V8-04; Android X8-05): the viewer page
    // over a player the rail card already holds shows the dark backdrop until the layer reports its
    // first frame, never the black ground of a frame already shown.
    @Test("a handed-over player's page shows the backdrop, not black, until its first frame")
    func handoverShowsNoBlackFrame() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("handover.mp4")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)
        let pool = MediaServices.current.videoPool
        let item = StoryItemConfig(type: .video, url: video.absoluteString, duration: nil)
        let key = storyPoolKey(namespace: MediaStage.campaign, index: 0)
        let url = try #require(URL(string: item.url))
        let tile = try #require(pool.borrow(key: key, url: url, priority: .railThumb))
        let handover = try #require(storyRailHandover(item: item, playing: true, key: key, pool: pool))

        let window = MediaStage.mount(viewer([item], handover: handover))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.2)

        #expect(pool.heldPlayer(for: key) === tile, "the page plays the card's own player")
        let image = ComponentTestHost.settledImage(of: window)
        let corner = pixelColor(
            of: image,
            atX: Int(((image.size.width - MediaStage.size.width) / 2 + 6) * image.scale),
            y: Int(((image.size.height - MediaStage.size.height) / 2 + 6) * image.scale))
        #expect(corner.map { colorsNearly($0, Self.backdrop, tolerance: 0.03) } == true, "the dark backdrop, not black")
        MediaOrigin.release(video)
    }

    /// Whether something lighter than the backdrop is drawn in the stage box.
    private static func lit(_ image: UIImage) -> Bool {
        let scale = image.scale
        let box = CGRect(
            x: (image.size.width - MediaStage.size.width) / 2, y: (image.size.height - MediaStage.size.height) / 2,
            width: MediaStage.size.width, height: MediaStage.size.height)
        return stride(from: box.minX + 4, to: box.maxX - 4, by: 2).contains { x in
            stride(from: box.minY + 4, to: box.maxY - 4, by: 2).contains { y in
                pixelColor(of: image, atX: Int(x * scale), y: Int(y * scale))
                    .map { !colorsNearly($0, backdrop, tolerance: 0.2) } ?? false
            }
        }
    }
}
}
