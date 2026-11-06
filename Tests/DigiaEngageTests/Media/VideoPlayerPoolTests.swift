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
    private func pool(size: Int) -> VideoPlayerPool {
        VideoPlayerPool(maxPlayers: size, makeItem: { AVPlayerItem(url: $0) })
    }

    private func url(_ name: String) -> URL { URL(string: "https://pool.test/\(name).mp4")! }

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

    // Guards `evictableTail` (lowest rank, then least recently borrowed) and `evict`'s observer call.
    @Test("a full pool takes back the lowest-ranked, least recently borrowed player first")
    func evictionOrder() {
        let pool = pool(size: 3)
        _ = pool.borrow(key: "rail-1", url: url("a"), priority: .railThumb)
        _ = pool.borrow(key: "rail-2", url: url("b"), priority: .railThumb)
        _ = pool.borrow(key: "next", url: url("c"), priority: .viewerNext)
        var evicted: [String] = []
        for key in ["rail-1", "rail-2", "next"] {
            _ = pool.observeEviction(of: key) { evicted.append(key) }
        }

        #expect(pool.borrow(key: "page", url: url("d"), priority: .onScreen) != nil)
        #expect(pool.borrow(key: "prev", url: url("e"), priority: .viewerPrev) != nil)

        #expect(evicted == ["rail-1", "rail-2"])
        #expect(pool.heldKeys == ["next", "page", "prev"])
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

    // Guards the extra-player branch in `borrow` and the over-size `destroy` in `giveBack` (OD-1).
    @Test("an on-screen borrow on a full pool gets an extra player, destroyed when given back")
    func onScreenBorrowGetsExtra() throws {
        let pool = pool(size: 1)
        _ = pool.borrow(key: "floater", url: url("a"), priority: .onScreen)
        let extra = try #require(pool.borrow(key: "pip", url: url("b"), priority: .onScreen))
        #expect(pool.livePlayerCount == 2)

        pool.giveBack(key: "pip", player: extra, priority: .onScreen)

        #expect(pool.livePlayerCount == 1)
        #expect(extra.currentItem == nil)
    }

    // Guards the `priority != .onScreen` refusal in `borrow`.
    @Test("a warm borrow on a full pool is refused")
    func warmBorrowOnFullPoolIsRefused() {
        let pool = pool(size: 1)
        _ = pool.borrow(key: "page", url: url("a"), priority: .onScreen)

        #expect(pool.borrow(key: "next", url: url("b"), priority: .viewerNext) == nil)
        #expect(pool.livePlayerCount == 1)
    }

    // Guards `holds.min()` in `Holder.priority` (R1-10).
    @Test("a warm borrow of a key held on screen keeps it on screen")
    func coHolderKeepsTheHighestRank() {
        let pool = pool(size: 2)
        _ = pool.borrow(key: "story-1", url: url("a"), priority: .onScreen)
        _ = pool.borrow(key: "story-1", url: url("a"), priority: .railThumb)
        _ = pool.borrow(key: "rail-2", url: url("b"), priority: .railThumb)

        #expect(pool.borrow(key: "next", url: url("c"), priority: .viewerNext) != nil)

        #expect(pool.heldKeys == ["story-1", "next"])
    }

    // Guards `holds.remove(at:)` in `giveBack` (OD-10, R2-06a).
    @Test("a key's rank drops when its on-screen hold is given back")
    func rankDropsWhenTheHigherHoldGoes() throws {
        let pool = pool(size: 2)
        let story = try #require(pool.borrow(key: "story-1", url: url("a"), priority: .onScreen))
        _ = pool.borrow(key: "story-1", url: url("a"), priority: .railThumb)
        _ = pool.borrow(key: "page", url: url("b"), priority: .onScreen)
        var evicted: [String] = []
        _ = pool.observeEviction(of: "story-1") { evicted.append("story-1") }

        pool.giveBack(key: "story-1", player: story, priority: .onScreen)

        #expect(pool.priority(of: "story-1") == .railThumb)
        #expect(pool.borrow(key: "next", url: url("c"), priority: .viewerNext) != nil)
        #expect(evicted == ["story-1"])
        #expect(pool.livePlayerCount == 2)
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
