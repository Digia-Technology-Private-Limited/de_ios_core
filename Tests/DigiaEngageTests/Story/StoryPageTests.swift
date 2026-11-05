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
