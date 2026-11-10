import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The pool's rules on bare players (no playback needed), then the two rules that need a mounted
// `MediaVideo`: a URL change under one key, and a remount resuming at its playhead.

@MainActor
@Suite("VideoPlayerPool", .tags(.media, .unit))
struct VideoPlayerPoolTests {
    private func pool(
        size: Int, ceiling: Int? = nil, time: FakeTime = FakeTime(), onRefused: @escaping @MainActor () -> Void = {}
    ) -> VideoPlayerPool {
        VideoPlayerPool(
            maxPlayers: size, ceiling: ceiling, onCeilingRefused: onRefused,
            clock: { time.now }, schedule: { time.schedule($0, $1) },
            makeItem: { AVPlayerItem(url: $0) })
    }

    private func url(_ name: String) -> URL { URL(string: "https://pool.test/\(name).mp4")! }

    /// A hand-wound clock and scheduler, so the 8 s park needs no waiting.
    final class FakeTime: @unchecked Sendable {
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

    // Guards the thresholds in `deviceClassFor` and the sizes in `maxPoolPlayers` (OD-1, OD-10): the
    // pool size per device class is a parity setting, so each boundary is pinned on both sides.
    @Test("the pool holds 2, 3 or 4 players by device memory, and 3 when memory is unknown")
    func poolSizePerDeviceClass() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        func size(_ bytes: UInt64) -> Int { maxPoolPlayers(deviceClass: deviceClassFor(physicalMemoryBytes: bytes)) }

        #expect(size(0) == 3, "unknown is the middle class")
        #expect(size(2 * gib) == 2)
        #expect(size(4 * gib - 1) == 2)
        #expect(size(4 * gib) == 3)
        #expect(size(7 * gib - 1) == 3)
        #expect(size(7 * gib) == 4)
        #expect(size(16 * gib) == 4)
    }

    // Guards `livePlayerCeiling` (OD-24): the four decoder sessions iOS is assumed to have, minus one
    // for the host app's own video, and never below the pool size.
    @Test("the live-player ceiling is three, or the pool size when that is larger")
    func ceilingFormula() {
        #expect(livePlayerCeiling(poolSize: 2) == 3)
        #expect(livePlayerCeiling(poolSize: 3) == 3)
        #expect(livePlayerCeiling(poolSize: 4) == 4)
        #expect(livePlayerCeiling(poolSize: 1, decoderSessions: 2) == 1)
    }

    // Guards the `holders.count >= ceiling` gate in `borrow`: below it every borrow of either stage
    // is served (an extra above the pool size) and nobody is taken back.
    @Test("below the ceiling everyone gets a player and nobody is evicted")
    func belowTheCeilingEveryoneIsServed() {
        let pool = pool(size: 1, ceiling: 4)
        var evicted = 0
        for (key, priority) in [("a", PoolPriority.onScreen), ("b", .onScreen), ("c", .viewerNext), ("d", .viewerPage)] {
            #expect(pool.borrow(key: key, url: url(key), priority: priority) != nil, "\(key)")
            _ = pool.observeEviction(of: key) { evicted += 1 }
        }

        #expect(pool.livePlayerCount == 4)
        #expect(evicted == 0)
    }

    // Guards the Stage-2 branch at the ceiling in `borrow`: refused (its still), and reported.
    @Test("a Stage-2 borrow at the ceiling is refused and reported")
    func stageTwoRefusedAtTheCeiling() {
        var refused = 0
        let pool = pool(size: 1, ceiling: 2, onRefused: { refused += 1 })
        _ = pool.borrow(key: "a", url: url("a"), priority: .onScreen)
        _ = pool.borrow(key: "b", url: url("b"), priority: .viewerPage)

        #expect(pool.borrow(key: "c", url: url("c"), priority: .onScreen) == nil)

        #expect(refused == 1)
        #expect(pool.heldKeys == ["a", "b"])
        #expect(pool.livePlayerCount == 2)
    }

    // Guards `.min(by: seq)` over the holders with no Stage-1 hold in `borrow`, and `evict`'s observer
    // call: Stage 1 takes the least recently borrowed Stage-2 holder, and that holder is told.
    @Test("Stage 1 at the ceiling takes the least recently borrowed Stage-2 holder")
    func stageOneTakesTheLeastRecentStageTwoHolder() throws {
        let pool = pool(size: 1, ceiling: 2)
        let first = try #require(pool.borrow(key: "a", url: url("a"), priority: .onScreen))
        _ = pool.borrow(key: "b", url: url("b"), priority: .onScreen)
        _ = pool.borrow(key: "a", url: url("a"), priority: .onScreen) // a is the most recent now
        var evicted: [String] = []
        for key in ["a", "b"] { _ = pool.observeEviction(of: key) { evicted.append(key) } }

        #expect(pool.borrow(key: "page", url: url("p"), priority: .viewerPage) != nil)

        #expect(evicted == ["b"])
        #expect(pool.heldKeys == ["a", "page"])
        #expect(pool.heldPlayer(for: "a") === first)
        #expect(pool.livePlayerCount == 2)
    }

    // Guards `holds.allSatisfy { !$0.isStage1 }` in `borrow` and the missing refusal for Stage 1: with
    // only Stage-1 holders at the ceiling, a Stage-1 borrow goes one over and takes nobody's player.
    @Test("Stage 1 never takes a Stage-1 holder's player and is never refused")
    func stageOneIsNeverRefusedAndNeverTakesStageOne() {
        let pool = pool(size: 1, ceiling: 2)
        _ = pool.borrow(key: "page", url: url("p"), priority: .viewerPage)
        _ = pool.borrow(key: "next", url: url("n"), priority: .viewerNext)
        var evicted = 0
        for key in ["page", "next"] { _ = pool.observeEviction(of: key) { evicted += 1 } }

        #expect(pool.borrow(key: "prev", url: url("v"), priority: .viewerPrev) != nil)

        #expect(evicted == 0)
        #expect(pool.livePlayerCount == 3, "one over the ceiling")
    }

    // Guards the per-hold check in `borrow` (R1-10, OD-24): a rail card borrowing the viewer page's key
    // adds a Stage-2 hold but never makes the key a Stage-2 holder, even when it is the oldest.
    @Test("a rail borrow of the viewer's key never makes it evictable")
    func railBorrowOfTheViewersKeyDoesNotMakeItEvictable() {
        let pool = pool(size: 1, ceiling: 2)
        _ = pool.borrow(key: "story-1", url: url("a"), priority: .viewerPage)
        _ = pool.borrow(key: "story-1", url: url("a"), priority: .onScreen)
        _ = pool.borrow(key: "other", url: url("b"), priority: .onScreen)
        var evicted: [String] = []
        for key in ["story-1", "other"] { _ = pool.observeEviction(of: key) { evicted.append(key) } }

        _ = pool.borrow(key: "next", url: url("c"), priority: .viewerNext)

        #expect(evicted == ["other"])
        #expect(pool.heldKeys == ["story-1", "next"])
    }

    // Guards `holds.remove(at:)` in `giveBack` (OD-10, R2-06a): once the viewer lets its page go, the key
    // is a Stage-2 holder again and the next Stage-1 borrow can take it.
    @Test("a key drops to Stage 2 when the viewer gives it back")
    func keyDropsToStageTwoWhenTheViewerLetsGo() throws {
        let pool = pool(size: 1, ceiling: 2)
        let story = try #require(pool.borrow(key: "story-1", url: url("a"), priority: .viewerPage))
        _ = pool.borrow(key: "story-1", url: url("a"), priority: .onScreen)
        _ = pool.borrow(key: "other", url: url("b"), priority: .viewerNext)
        var evicted: [String] = []
        _ = pool.observeEviction(of: "story-1") { evicted.append("story-1") }

        pool.giveBack(key: "story-1", player: story, priority: .viewerPage)
        #expect(pool.priority(of: "story-1") == .onScreen)
        _ = pool.borrow(key: "page", url: url("c"), priority: .viewerPage)

        #expect(evicted == ["story-1"])
        #expect(pool.livePlayerCount == 2)
    }

    // Guards `player.pause()` in `giveBack`.
    @Test("giving a player back pauses it")
    func giveBackPauses() throws {
        let pool = pool(size: 2)
        let player = try #require(pool.borrow(key: "k", url: url("a"), priority: .onScreen))
        player.play()
        #expect(player.rate > 0)

        pool.giveBack(key: "k", player: player, priority: .onScreen)

        #expect(player.rate == 0)
        #expect(pool.heldKeys.isEmpty)
    }

    // Guards `parked` and `scheduleTrim` in `giveBack`, and the age check and reschedule in `trimParked`
    // (OD-24): an extra given back is kept, not destroyed; each is destroyed once it has been parked
    // 8 s, oldest first, and a younger one waits for its own 8 s.
    @Test("an extra player given back is parked, then destroyed 8 s later, each on its own clock")
    func extrasAreParkedThenDestroyed() throws {
        let time = FakeTime()
        let pool = pool(size: 1, ceiling: 4, time: time)
        _ = pool.borrow(key: "a", url: url("a"), priority: .onScreen)
        let extra1 = try #require(pool.borrow(key: "b", url: url("b"), priority: .onScreen))
        let extra2 = try #require(pool.borrow(key: "c", url: url("c"), priority: .onScreen))

        pool.giveBack(key: "b", player: extra1, priority: .onScreen)
        #expect(extra1.currentItem != nil, "parked, not destroyed")
        time.advance(to: 5)
        pool.giveBack(key: "c", player: extra2, priority: .onScreen)
        time.advance(to: 7.9)
        #expect(pool.livePlayerCount == 3, "nothing is 8 s old yet")

        time.advance(to: 8)
        #expect(extra1.currentItem == nil, "the first extra is destroyed at 8 s")
        #expect(extra2.currentItem != nil, "the younger one waits")
        #expect(pool.livePlayerCount == 2)

        time.advance(to: 13)
        #expect(extra2.currentItem == nil)
        #expect(pool.livePlayerCount == 1, "back to the pool's size")
    }

    // Guards the free-player reuse in `borrow` for a parked extra (OD-24): a borrow within the park
    // makes no new player, and the reused one is not trimmed from under its holder.
    @Test("a parked extra is reused by the next borrow and survives the trim while held")
    func parkedExtraIsReused() throws {
        let time = FakeTime()
        let pool = pool(size: 1, ceiling: 4, time: time)
        _ = pool.borrow(key: "a", url: url("a"), priority: .onScreen)
        let extra = try #require(pool.borrow(key: "b", url: url("b"), priority: .onScreen))
        pool.giveBack(key: "b", player: extra, priority: .onScreen)
        time.advance(to: 3)

        let reused = try #require(pool.borrow(key: "c", url: url("c"), priority: .onScreen))
        time.advance(to: 20)

        #expect(reused === extra)
        #expect(pool.livePlayerCount == 2)
        #expect(reused.currentItem != nil)
    }

    // Guards `onMemoryPressure` (OD-24): idle players (free and parked) are destroyed, and so are the
    // players held only as the story's previous page, whose holders are told; everything else stays.
    @Test("memory pressure destroys idle players and the previous-page hold, and nothing else")
    func memoryPressureReleasesIdlePlayers() throws {
        let pool = pool(size: 2, ceiling: 6)
        _ = pool.borrow(key: "page", url: url("p"), priority: .viewerPage)
        _ = pool.borrow(key: "next", url: url("n"), priority: .viewerNext)
        let prev = try #require(pool.borrow(key: "prev", url: url("v"), priority: .viewerPrev))
        _ = pool.borrow(key: "shared", url: url("s"), priority: .viewerPrev)
        _ = pool.borrow(key: "shared", url: url("s"), priority: .onScreen)
        let idleA = try #require(pool.borrow(key: "idle-a", url: url("x"), priority: .onScreen))
        let idleB = try #require(pool.borrow(key: "idle-b", url: url("y"), priority: .onScreen))
        pool.giveBack(key: "idle-a", player: idleA, priority: .onScreen)
        pool.giveBack(key: "idle-b", player: idleB, priority: .onScreen)
        var told: [String] = []
        for key in ["prev", "shared", "next"] { _ = pool.observeEviction(of: key) { told.append(key) } }

        pool.onMemoryPressure()

        #expect(pool.heldKeys == ["page", "next", "shared"])
        #expect(told == ["prev"])
        #expect(prev.currentItem == nil)
        #expect(idleA.currentItem == nil && idleB.currentItem == nil)
        #expect(pool.livePlayerCount == 3)
    }

    // Guards `notifyEvicted(key)` after a re-point in `borrow` (OD-10, R2-06c).
    @Test("a borrow of a held key with another URL tells the other holders")
    func repointTellsTheOtherHolders() throws {
        let pool = pool(size: 2)
        let player = try #require(pool.borrow(key: "canvas", url: url("light"), priority: .onScreen))
        var told = 0
        _ = pool.observeEviction(of: "canvas") { told += 1 }

        let repointed = try #require(pool.borrow(key: "canvas", url: url("dark"), priority: .onScreen))

        #expect(repointed === player)
        #expect(told == 1)
        // The old holder's hold ended with the notice: the new holder's give-back frees it.
        pool.giveBack(key: "canvas", player: repointed, priority: .onScreen)
        #expect(pool.heldKeys.isEmpty)
    }

    // Guards the removals in `giveBack` and `removeEvictionObserver` (N8).
    @Test("bookkeeping stays bounded by the live players")
    func bookkeepingIsBounded() {
        let pool = pool(size: 2)
        for index in 0 ..< 50 {
            let key = "card-\(index)"
            guard let player = pool.borrow(key: key, url: url("v\(index % 7)"), priority: .onScreen) else { continue }
            let observer = pool.observeEviction(of: key) {}
            pool.removeEvictionObserver(observer, for: key)
            pool.giveBack(key: key, player: player, priority: .onScreen)
        }

        #expect(pool.bookkeepingCount <= pool.maxPlayers)
    }

    // MARK: Refusal retry

    private func open(
        _ playback: MediaVideoPlayback, key: String, pool: VideoPlayerPool, lost: CallCount
    ) {
        var services = MediaServices.current
        services.videoPool = pool
        playback.updateCallbacks(onFirstFrame: nil, onEnded: nil, onFailure: nil, onLost: { lost.value += 1 })
        playback.open(
            url: url(key).absoluteString, key: key, priority: .onScreen, loop: false, muted: true, volume: 1,
            autoplay: false, spinnerDelay: nil, services: services, report: { _ in })
    }

    // Guards the main-queue retry in `MediaVideoPlayback.open` (OD-24): a surface that asks for a player in
    // the same turn as the one it replaces (the rail's next card) is refused at the ceiling, then gets the
    // player the leaving one gives back, and nobody gives up.
    @Test("a surface replacing another in the same turn at the ceiling gets the freed player")
    func refusedBorrowIsRetriedOnceTheLeavingSurfaceLetsGo() async throws {
        let pool = pool(size: 1, ceiling: 1)
        let lost = CallCount()
        let leaving = MediaVideoPlayback(), arriving = MediaVideoPlayback()
        open(leaving, key: "card-0", pool: pool, lost: lost)
        #expect(leaving.player != nil)

        open(arriving, key: "card-1", pool: pool, lost: lost) // refused: the pool is at its ceiling
        #expect(arriving.player == nil)
        leaving.close() // the leaving card's onDisappear, after the arriving card's onAppear

        #expect(await waitUntilMedia(timeout: 2) { arriving.player != nil }, "the retry got the freed player")
        #expect(lost.value == 0)
        #expect(pool.heldKeys == ["card-1"])
        arriving.close()
    }

    // Guards `guard retried else` in `MediaVideoPlayback.open`: a second refusal behaves as before, one
    // `onLost` and no player.
    @Test("a borrow refused again on the retry gives up once")
    func secondRefusalGivesUp() async throws {
        let pool = pool(size: 1, ceiling: 1)
        let lost = CallCount()
        let holder = MediaVideoPlayback(), refused = MediaVideoPlayback()
        open(holder, key: "card-0", pool: pool, lost: lost)

        open(refused, key: "card-1", pool: pool, lost: lost)
        #expect(lost.value == 0, "not yet: the retry comes first")
        #expect(await waitUntilMedia(timeout: 2) { lost.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.1)

        #expect(lost.value == 1)
        #expect(refused.player == nil)
        holder.close()
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
