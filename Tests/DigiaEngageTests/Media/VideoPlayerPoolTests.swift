import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage
@testable import DigiaVideoEngine

// The pool rules that need a mounted `MediaVideo`: a URL change under one key, and a remount
// resuming at its playhead. The pool's rules on bare players and the shared pool cases run in
// the engine's own tests (`DigiaVideoEngineTests`).

/// A hand-wound clock for the pool: `schedule` queues a task, `advance` runs the ones due.
private final class PoolFakeTime: @unchecked Sendable {
    var now: TimeInterval = 0
    private var tasks: [(due: TimeInterval, task: @MainActor () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ task: @escaping @MainActor () -> Void) {
        tasks.append((now + delay, task))
    }

    @MainActor
    func advance(to time: TimeInterval) {
        while let next = tasks.filter({ $0.due <= time }).min(by: { $0.due < $1.due }) {
            tasks.removeAll { $0.due == next.due }
            now = next.due
            next.task()
        }
        now = time
    }
}

/// Mounts a keyed `MediaVideo` once and drives it through state: shown or not, and its URL.
@MainActor
private final class PooledVideoModel: ObservableObject {
    @Published var shown = true
    @Published var url: String
    var frames = 0
    var failures = 0

    init(url: String) { self.url = url }
}

private struct PooledVideoHost: View {
    @ObservedObject var model: PooledVideoModel

    var body: some View {
        if model.shown {
            MediaVideo(url: model.url, autoplay: false, playerKey: "card", onFirstFrame: { model.frames += 1 },
                       onFailure: { model.failures += 1 })
        }
    }
}

extension RenderedUITests {
@MainActor
@Suite("VideoPlayerPool with MediaVideo", .serialized, .tags(.media, .component))
struct VideoPlayerPoolMediaVideoTests {
    // Guards `giveBack` in `MediaVideoPlayback.close`, which `open` runs before a new URL (N5).
    @Test("a URL change under the same key frees the old holder")
    func urlChangeFreesTheOldHolder() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let light = MediaOrigin.url("light.mp4")
        let dark = MediaOrigin.url("dark.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: light)
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: dark)
        let pool = MediaServices.current.videoPool
        let model = PooledVideoModel(url: light.absoluteString)

        let window = MediaStage.mount(PooledVideoHost(model: model))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { model.frames == 1 })
        model.url = dark.absoluteString
        #expect(await waitUntilMedia { model.frames == 2 })
        model.shown = false
        ComponentTestHost.drainRunLoop(for: 0.1)

        // The dark showing's hold was the only one: nothing stays held for either URL.
        #expect(pool.heldKeys.isEmpty)
    }

    // Guards the `reused.key != key || reused.finished` restart check in `VideoPlayerPool.borrow` (N2).
    @Test("a remount with the same key and URL resumes at its playhead")
    func remountResumesAtThePlayhead() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("resume.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let pool = MediaServices.current.videoPool
        let model = PooledVideoModel(url: video.absoluteString)

        let window = MediaStage.mount(PooledVideoHost(model: model))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { model.frames == 1 })
        let player = try #require(pool.heldPlayer(for: "card"))
        var seeked = false
        player.seek(to: CMTime(seconds: 3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            seeked = true
        }
        #expect(await waitUntilMedia { seeked })

        model.shown = false
        ComponentTestHost.drainRunLoop(for: 0.1)
        model.shown = true
        #expect(await waitUntilMedia { model.frames == 2 })

        #expect(pool.heldPlayer(for: "card") === player)
        #expect(abs(player.currentTime().seconds - 3) < 0.1)
}

    /// The SDK's video services with a pool on a hand-wound clock, its items reading through the
    /// range cache on `MediaOrigin`.
    private func poolOnFakeTime() -> (VideoPlayerPool, PoolFakeTime) {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        let time = PoolFakeTime()
        let loader = MediaServices.current.videoLoader
        let pool = VideoPlayerPool(
            maxPlayers: 2, clock: { time.now }, schedule: { time.schedule($0, $1) },
            makeItem: { mediaVideoItem(for: $0, loader: loader) },
            releaseItem: { loader.cancelLoading(for: $0) })
        MediaServices.override(videoPool: pool)
        return (pool, time)
    }

    // Guards `replaceItem(of: free[index].player, with: nil)` in `VideoPlayerPool.trimParked` and
    // `releaseItem(old)` in `replaceItem`: an idle player's item keeps reading its file through the
    // range cache, so a page the user left downloaded the whole video. Letting go of the item alone
    // stops nothing (AVFoundation sends no `didCancel`); the pool cancels its requests.
    @Test("a player given back stops downloading its video once it has been idle 8 s")
    func idlePlayerStopsDownloading() async throws {
        let (_, time) = poolOnFakeTime()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("idle.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video, held: true)
        let model = PooledVideoModel(url: video.absoluteString)

        let window = MediaStage.mount(PooledVideoHost(model: model))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { MediaOrigin.heldOpen(for: video) == 1 }, "the page is downloading")
        model.shown = false
        ComponentTestHost.drainRunLoop(for: 0.1)
        #expect(MediaOrigin.heldOpen(for: video) == 1, "given back, the player keeps its item for a remount")
        time.advance(to: VideoPlayerPool.parkSeconds)

        #expect(await waitUntilMedia { MediaOrigin.heldOpen(for: video) == 0 }, "the download is cancelled")
    }

    // Guards `startMs ?? pool.takeResumeMs(...)` in `MediaVideoPlayback.open`: a player whose idle
    // item was let go gets a new one, which must not restart at 0 (N2 past the 8 s).
    @Test("a remount after the idle item was let go resumes at the old playhead")
    func remountAfterIdleResumes() async throws {
        let (pool, time) = poolOnFakeTime()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("resume-idle.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let model = PooledVideoModel(url: video.absoluteString)

        let window = MediaStage.mount(PooledVideoHost(model: model))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { model.frames == 1 })
        let player = try #require(pool.heldPlayer(for: "card"))
        var seeked = false
        player.seek(to: CMTime(seconds: 3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            seeked = true
        }
        #expect(await waitUntilMedia { seeked })
        model.shown = false
        ComponentTestHost.drainRunLoop(for: 0.1)
        time.advance(to: VideoPlayerPool.parkSeconds)
        #expect(player.currentItem == nil, "the idle item was let go")

        model.shown = true

        #expect(await waitUntilMedia { model.frames == 2 })
        #expect(pool.heldPlayer(for: "card") === player)
        #expect(abs(player.currentTime().seconds - 3) < 0.1)
    }

    // Guards the `hasFailed` checks in `VideoPlayerPool.borrow` (R2-02): an AVPlayerItem never
    // recovers, so a pooled player that failed must get a new item before the next holder.
    @Test("a keyed video that failed plays on its next mount once the origin serves again")
    func failedPlayerIsNotInherited() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("flaky.mp4")
        MediaOrigin.set(.fail(.notConnectedToInternet), for: video)
        let model = PooledVideoModel(url: video.absoluteString)

        let window = MediaStage.mount(PooledVideoHost(model: model))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { model.failures == 1 })

        model.shown = false
        ComponentTestHost.drainRunLoop(for: 0.1)
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        model.shown = true

        #expect(await waitUntilMedia { model.frames == 1 })
        #expect(model.failures == 1)
    }
}
}
