import AVFoundation
import Foundation
import Testing

@testable import DigiaEngage

// How the viewer's window reaches the pool and the caches (T8): the rail's handover keeps the
// card's player for the viewer, the driver keeps the players either side until the new page's
// first frame, neighbours wait paused and muted at their playhead, and the bytes two pages away
// are warmed through `MediaPrefetch`. Real `VideoPlayerPool`s on bare players; only the warm is
// recorded.

private final class WarmLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var all: [String] { lock.withLock { calls } }
    func add(_ call: String) { lock.withLock { calls.append(call) } }
}

@MainActor
@Suite("Story plan driver", .tags(.inline, .media, .unit))
struct StoryPlanDriverTests {
    /// Five video stories. The players play the Test Kit's movie from disk, so an item never fails
    /// (a failed item is replaced on its next borrow, which would hide a reload).
    private let stories: [StoryItemConfig] = {
        let movie = FixtureLoader.workspaceURL()?.appendingPathComponent("testkit/mock-server/assets/movie.mp4")
        return (0..<5).map { _ in StoryItemConfig(type: .video, url: movie?.absoluteString ?? "", duration: nil) }
    }()
    private let remote = (0..<5).map { StoryItemConfig(type: .video, url: "https://plan.test/\($0).mp4", duration: nil) }

    private func pool(size: Int) -> VideoPlayerPool {
        VideoPlayerPool(maxPlayers: size, makeItem: { AVPlayerItem(url: $0) })
    }

    private func key(_ index: Int) -> String { storyPoolKey(namespace: "c", index: index) }

    private func update(
        _ driver: StoryPlanDriver, at index: Int, firstFrameShown: Bool, slow: Bool = false,
        stories: [StoryItemConfig]? = nil
    ) {
        let stories = stories ?? self.stories
        driver.update(
            actions: StoryDownloadPlan.plan(
                stories: stories.map { _ in .init(isVideo: true) }, currentIndex: index,
                firstFrameShown: firstFrameShown, slowNetwork: slow),
            urlOf: { stories[$0].url },
            isVideoOf: { _ in true },
            keyOf: { key($0) },
            keepPlayersFor: [index - 1, index + 1]
        )
    }

    // Guards the `pool.borrow(key: key, url: url, priority: .onScreen)` hold in `storyRailHandover`.
    // Without it the card's player goes back to the free list in the gap, and the next borrow under
    // another key takes it and loads another video into it.
    @Test("tapping a playing card hands its player to the viewer, never freed or reused in between")
    func handoverKeepsTheCardsPlayer() throws {
        let pool = pool(size: 1)
        let card = stories[0]
        let tile = try #require(pool.borrow(key: key(0), url: URL(string: card.url)!, priority: .railThumb))
        let item = tile.currentItem

        let handover = storyRailHandover(item: card, playing: true, key: key(0), pool: pool)
        // The card lets go as the viewer covers it, and something else asks for a player before
        // the page borrows.
        pool.giveBack(key: key(0), player: tile, priority: .railThumb)
        _ = pool.borrow(key: key(1), url: URL(string: stories[1].url)!, priority: .viewerNext)
        let page = pool.borrow(key: key(0), url: URL(string: card.url)!, priority: .onScreen)
        handover?.release()

        #expect(handover != nil)
        #expect(page === tile, "the viewer's page plays the card's own player")
        #expect(page?.currentItem === item, "with the same item: nothing reloads, no black frame")
    }

    // Guards the `playing` check in `storyRailHandover`.
    @Test("a tap on a card that is not playing opens the viewer with nothing handed over")
    func stillCardHandsNothingOver() throws {
        let pool = pool(size: 2)
        _ = try #require(pool.borrow(key: key(0), url: URL(string: stories[0].url)!, priority: .railThumb))

        #expect(storyRailHandover(item: stories[0], playing: false, key: key(0), pool: pool) == nil)
        #expect(storyRailHandover(item: stories[1], playing: true, key: key(1), pool: pool) == nil, "no player to hand over")
    }

    // Guards `if keep.contains(index)` in `StoryPlanDriver.updatePlayers`.
    @Test("until the new page's first frame the players either side stay, those further away go")
    func neighboursStayUntilTheFirstFrame() throws {
        let pool = pool(size: 4)
        let driver = StoryPlanDriver(pool: pool, warm: { _, _, _ in 0 })
        update(driver, at: 1, firstFrameShown: true)
        #expect(driver.heldIndices == [0, 1, 2])
        let left = try #require(driver.heldPlayer(for: 1))

        // Swiped on to 2; its first frame has not shown yet.
        update(driver, at: 2, firstFrameShown: false)

        #expect(driver.heldIndices == [1, 2], "page 1 (just left) stays, page 0 (two away) goes")
        #expect(pool.heldKeys == [key(1), key(2)])
        #expect(driver.heldPlayer(for: 1) === left)
        driver.cancelAll()
        #expect(pool.heldKeys.isEmpty)
    }

    // Guards `prepareNeighbour` (pause and mute, no seek) for a kept and a ranked-down page.
    @Test("the page left waits paused and muted at its playhead, so swiping back resumes it (N9)")
    func pageLeftWaitsAtItsPlayhead() throws {
        let pool = pool(size: 4)
        let driver = StoryPlanDriver(pool: pool, warm: { _, _, _ in 0 })
        update(driver, at: 1, firstFrameShown: true)
        let left = try #require(driver.heldPlayer(for: 1))
        let item = left.currentItem
        left.isMuted = false
        left.play()

        update(driver, at: 2, firstFrameShown: false)
        #expect(left.rate == 0, "the page left does not play on behind the new one")
        #expect(left.isMuted)
        update(driver, at: 2, firstFrameShown: true)

        // Swiping back borrows page 1's key: the same player, with the same item.
        let back = pool.borrow(key: key(1), url: URL(string: stories[1].url)!, priority: .onScreen)
        #expect(back === left)
        #expect(back?.currentItem === item)
        #expect(pool.priority(of: key(1)) == .onScreen)
        driver.cancelAll()
    }

    // Guards the `.firstBytes` arm of `StoryPlanDriver.updateBytes`.
    @Test("the first bytes two pages ahead and behind are warmed through MediaPrefetch")
    func firstBytesAreWarmed() async {
        let log = WarmLog()
        let driver = StoryPlanDriver(pool: pool(size: 4), warm: { url, kind, bytes in
            log.add("\(url) \(kind) \(bytes.map(String.init) ?? "-")")
            return bytes ?? 0
        })
        update(driver, at: 2, firstFrameShown: true, stories: remote)
        _ = await waitUntilMedia(timeout: 2) { log.all.count >= 2 }

        #expect(Set(log.all) == [
            "https://plan.test/4.mp4 video \(storyFirstBytes)",
            "https://plan.test/0.mp4 video \(storyFirstBytes)",
        ])
        driver.cancelAll()
    }

    /// Answers after `seconds` whatever the task's state: a warm that does not notice a cancel.
    private static func laterNoMatterWhat(_ seconds: Double, _ value: Int) async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume(returning: value) }
        }
    }

    /// A throughput seeded with one 512 KiB sample that took `seededElapsed` seconds (10 reads as
    /// slow, 0.5 as fast), fed by a driver whose warms answer `delivered` (nil: all that was asked)
    /// after 0.1 s. Every warm the driver reports is taken as lasting `reportedElapsed` seconds, so
    /// the verdict never depends on the real clock; `act` gets a log with one entry per report to
    /// wait on.
    private func verdict(
        seededElapsed: TimeInterval, reportedElapsed: TimeInterval = 0.5, delivered: Int?,
        then act: (StoryPlanDriver, WarmLog) async -> Void
    ) async -> SlowNetworkThroughput {
        let throughput = SlowNetworkThroughput()
        throughput.note(bytes: storyFirstBytes, elapsed: seededElapsed)
        let reports = WarmLog()
        let driver = StoryPlanDriver(
            pool: pool(size: 4),
            warm: { _, _, bytes in await Self.laterNoMatterWhat(0.1, delivered ?? bytes ?? 0) },
            onWarm: { bytes, _ in
                throughput.note(bytes: bytes, elapsed: reportedElapsed)
                reports.add("\(bytes)")
            })
        update(driver, at: 2, firstFrameShown: true, stories: remote)
        await act(driver, reports)
        driver.cancelAll()
        return throughput
    }

    private func isSlow(_ throughput: SlowNetworkThroughput) -> Bool {
        slowNetworkFor(isExpensive: false, isConstrained: false, measuredKbps: throughput.lastKbps)
    }

    // Guards `guard !Task.isCancelled` ahead of `onWarm` in `StoryPlanDriver.updateBytes` (V8-01):
    // a warm the plan moved on from, though it ended with bytes in hand, measured nothing.
    @Test("a warm cancelled when the plan moves on leaves a slow verdict slow")
    func cancelledWarmDoesNotVote() async {
        let throughput = await verdict(seededElapsed: 10, delivered: nil) { driver, _ in
            try? await Task.sleep(nanoseconds: 30_000_000)
            driver.cancelAll()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        #expect(isSlow(throughput), "the cancelled warm's sample would read as a fast link")
    }

    // Guards the 0-byte discard in `SlowNetworkThroughput.note`, which `updateBytes` feeds: a warm
    // that failed delivers 0 bytes and votes nothing (counted, it would read 0 kbps and flip a fast
    // verdict to slow), while one that completed does (the control: the vote is wired).
    @Test("a failed warm votes nothing, a completed one does")
    func onlyACompletedWarmVotes() async {
        let failed = await verdict(seededElapsed: 0.5, delivered: 0) { _, reports in
            _ = await waitUntilMedia(timeout: 5) { !reports.all.isEmpty }
        }
        #expect(!isSlow(failed), "a warm that delivered nothing left the verdict as it was")

        let completed = await verdict(seededElapsed: 0.5, reportedElapsed: 10, delivered: nil) { _, reports in
            _ = await waitUntilMedia(timeout: 5) { !reports.all.isEmpty }
        }
        #expect(isSlow(completed), "a completed 512 KiB warm taking 10 s is a slow link")
    }
}
