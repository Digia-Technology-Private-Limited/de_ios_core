import AVFoundation
import Foundation
import Testing
import UIKit

@testable import DigiaEngage

// The byte-driving contract (T10): which plan action calls which warmer, and that leaving the
// window cancels in-flight work while bytes already written stay on disk. The warmer is the
// `MediaPrefetch` protocol (lane H owns the implementation); the fake below pins the routing.
// Same cases as Android's `StoryPlanDriverTest`.

private final class FakeStoryPrefetch: MediaPrefetch, @unchecked Sendable {
    private let lock = NSLock()
    private var _ranged: [(String, Int)] = []
    private var _whole: [String] = []
    private var _images: [String] = []
    private var _cancelled = 0
    var gate = false

    var ranged: [(String, Int)] { lock.withLock { _ranged } }
    var whole: [String] { lock.withLock { _whole } }
    var images: [String] { lock.withLock { _images } }
    var cancelled: Int { lock.withLock { _cancelled } }

    func warmVideoBytes(url: String, lengthBytes: Int) async -> Int {
        if gate {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            lock.withLock { _cancelled += 1 }
            return 0
        }
        lock.withLock { _ranged.append((url, lengthBytes)) }
        return lengthBytes
    }

    func warmWholeVideo(url: String) async -> Int {
        lock.withLock { _whole.append(url) }
        return 0
    }

    func enqueueImage(_ url: String) {
        lock.withLock { _images.append(url) }
    }

    func warmImage(_ url: String) async -> UIImage? { nil }

    func warmLottie(_ url: String) async -> Bool { false }
}

private func storyURL(_ index: Int) -> String { "https://media.test/\(index).mp4" }
private func storyIsVideo(_ index: Int) -> Bool { index != 7 }

private func poll(
    _ condition: @autoclosure () -> Bool,
    timeout: TimeInterval = 2
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@Suite("StoryPlanDriver", .tags(.media, .unit))
struct StoryPlanDriverTests {
    // Fails if `firstBytes` warms the wrong range: the `warmVideoBytes(url, storyFirstBytes)`
    // call in `update`.
    @Test("first bytes warms the head range only")
    func firstBytesWarmsTheHeadRangeOnly() async {
        let prefetch = FakeStoryPrefetch()
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.firstBytes(index: 1)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        #expect(await poll(prefetch.ranged.count == 1))
        #expect(prefetch.ranged.first?.0 == storyURL(1))
        #expect(prefetch.ranged.first?.1 == storyFirstBytes)
        #expect(prefetch.whole.isEmpty)
        #expect(prefetch.images.isEmpty)
        driver.cancelAll()
    }

    // Fails if a video `wholeFile` warms a head range instead: the `warmWholeVideo(url)` call.
    @Test("a whole video file warms to the end")
    func wholeVideoFileWarmsToTheEnd() async {
        let prefetch = FakeStoryPrefetch()
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.wholeFile(index: 1)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        #expect(await poll(prefetch.whole == [storyURL(1)]))
        #expect(prefetch.ranged.isEmpty)
        driver.cancelAll()
    }

    // Fails if an image `wholeFile` warms video bytes: the `enqueueImage(url)` call.
    @Test("a whole file image enqueues instead of warming")
    func wholeFileImageEnqueuesInsteadOfWarming() async {
        let prefetch = FakeStoryPrefetch()
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.wholeFile(index: 7)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        // `enqueueImage` is synchronous: no wait needed.
        #expect(prefetch.images == [storyURL(7)])
        #expect(prefetch.ranged.isEmpty)
        #expect(prefetch.whole.isEmpty)
        driver.cancelAll()
    }

    // Fails if a player action warms bytes: the `.player -> break` arm in `update`.
    @Test("players do no byte work")
    func playersDoNoByteWork() async {
        let prefetch = FakeStoryPrefetch()
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.player(index: 1, priority: .onScreen)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(prefetch.ranged.isEmpty)
        #expect(prefetch.whole.isEmpty)
        #expect(prefetch.images.isEmpty)
        driver.cancelAll()
    }

    // Fails if leaving the window does not cancel: the stale-tasks `cancel()` in `update`.
    @Test("leaving the window cancels in-flight work")
    func leavingTheWindowCancelsInFlightWork() async {
        let prefetch = FakeStoryPrefetch()
        prefetch.gate = true
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.firstBytes(index: 1)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        driver.update(
            actions: [.firstBytes(index: 5)],
            urlOf: storyURL, isVideoOf: storyIsVideo)

        #expect(await poll(prefetch.cancelled == 1))
        driver.cancelAll()
    }

    // Fails if `cancelAll` spares jobs: the cancel loop in `cancelAll`.
    @Test("cancel all stops everything")
    func cancelAllStopsEverything() async {
        let prefetch = FakeStoryPrefetch()
        prefetch.gate = true
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.firstBytes(index: 1), .firstBytes(index: 2)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        driver.cancelAll()

        #expect(await poll(prefetch.cancelled == 2))
    }
}

// The player-lease half (R2-STORY): `.player` actions hold pool leases under the same
// campaign-namespaced keys the pages borrow under, so a swipe hands over the same instance.
// The real pool + a fake factory, file URLs (no fetch: a lease never plays) — mirrors
// Android's `StoryPlanDriverPlayerTest` (intended difference: iOS holds leases, Android
// prepares players; both hand over the same instance under the same key).

private final class LeaseFakeFactory: PlayerFactory {
    var creates = 0
    func makePlayer() -> AVQueuePlayer {
        creates += 1
        return AVQueuePlayer()
    }
}

private func leaseURL(_ index: Int) -> String {
    "file:///tmp/story-driver-test/\(index).mp4"
}

private func leaseKey(_ index: Int) -> String { "test/story-\(index)" }

private func leaseVideos(_ count: Int) -> [StoryDownloadPlan.Item] {
    (0..<count).map { _ in StoryDownloadPlan.Item(isVideo: true) }
}

@Suite("StoryPlanDriver leases", .tags(.media, .unit))
@MainActor
struct StoryPlanDriverLeaseTests {
    private func pool(factory: LeaseFakeFactory, maxPlayers: Int) -> VideoPlayerPool {
        VideoPlayerPool(factory: factory, maxPlayers: maxPlayers)
    }

    private func update(
        _ driver: StoryPlanDriver, _ pool: VideoPlayerPool,
        _ count: Int, at index: Int, firstFrameShown: Bool = true
    ) {
        driver.update(
            actions: StoryDownloadPlan.plan(
                stories: leaseVideos(count),
                currentIndex: index,
                firstFrameShown: firstFrameShown,
                slowNetwork: false
            ),
            urlOf: leaseURL, isVideoOf: { _ in true },
            keyOf: leaseKey, pool: pool)
    }

    // Fails if neighbour leases are not held under the page keys: without the `.player`
    // arm's `obtainLease` in `updatePlayerLeases` the window@2 holds nothing.
    @Test("neighbours hold leases under the page keys")
    func neighboursHoldLeasesUnderPageKeys() {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory, maxPlayers: 5)
        let driver = StoryPlanDriver(prefetch: FakeStoryPrefetch())
        defer { driver.cancelAll() }

        update(driver, pool, 5, at: 2)

        #expect(pool.heldKeys() == [leaseKey(2), leaseKey(1), leaseKey(3)])
        #expect(factory.creates == 3)
    }

    // Fails if priorities are not threaded into the lease: without the action's priority in
    // the `obtainLease` call the on-screen holder cannot outrank a viewer-next rival — the
    // rival evicts it. Pinned at onScreen by two rival probes (viewerNext AND onScreen both
    // refused: a strictly-lower rank would yield to the onScreen rival).
    @Test("the current holder outranks a viewer-next rival")
    func currentHolderOutranksViewerNextRival() {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory, maxPlayers: 1)
        let driver = StoryPlanDriver(prefetch: FakeStoryPrefetch())
        defer { driver.cancelAll() }

        update(driver, pool, 5, at: 2)
        #expect(pool.heldKeys() == [leaseKey(2)])

        let rivalNext = pool.obtain(
            key: "test/rival", url: URL(string: leaseURL(9))!, priority: .viewerNext)
        let rivalScreen = pool.obtain(
            key: "test/rival", url: URL(string: leaseURL(9))!, priority: .onScreen)
        #expect(rivalNext == nil)
        #expect(rivalScreen == nil)
        #expect(pool.heldKeys() == [leaseKey(2)])
    }

    // Fails if leaving the window does not release: without the held-minus-wanted `release`
    // in `updatePlayerLeases` the swipe@4 keeps the old holders (bytes stay on disk either
    // way — only holders go back so the pool can reuse them).
    @Test("leaving the window releases holders")
    func leavingTheWindowReleasesHolders() {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory, maxPlayers: 5)
        let driver = StoryPlanDriver(prefetch: FakeStoryPrefetch())
        defer { driver.cancelAll() }

        update(driver, pool, 6, at: 2)
        update(driver, pool, 6, at: 4)

        #expect(!pool.heldKeys().contains(leaseKey(1)))
        #expect(!pool.heldKeys().contains(leaseKey(2)))
        #expect(pool.heldKeys().contains(leaseKey(4)))
        #expect(pool.heldKeys().contains(leaseKey(3)))
    }

    // Fails if a swipe does not hand over the same instance: without obtaining under the
    // same key the pool's existing-key branch never serves the identical player. Fails if
    // the re-obtain does not raise the priority: without re-obtaining the held key the
    // swipe keeps the stale viewer-next rank (pinned by the rival probe above).
    @Test("swipe to next hands the same instance")
    func swipeToNextHandsTheSameInstance() {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory, maxPlayers: 5)
        let driver = StoryPlanDriver(prefetch: FakeStoryPrefetch())
        defer { driver.cancelAll() }

        update(driver, pool, 5, at: 2)
        let before = pool.obtainLease(key: leaseKey(3), url: leaseURL(3), priority: .railThumb)
        let first = before?.player
        #expect(first != nil)
        before?.release()

        update(driver, pool, 5, at: 3)
        let after = pool.obtainLease(key: leaseKey(3), url: leaseURL(3), priority: .railThumb)
        defer { after?.release() }

        #expect(after?.player === first)
    }

    // Fails if a refused obtain stops the window: without tolerating the nil borrow the
    // single slot goes to the wrong index or traps. The current index is obtained first
    // (serving order), so it wins the only slot and the neighbours degrade to stills.
    @Test("a refused obtain is tolerated and the current wins the slot")
    func refusedObtainToleratedCurrentWinsSlot() {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory, maxPlayers: 1)
        let driver = StoryPlanDriver(prefetch: FakeStoryPrefetch())
        defer { driver.cancelAll() }

        update(driver, pool, 3, at: 0)

        #expect(pool.heldKeys() == [leaseKey(0)])
        #expect(factory.creates == 1)
    }

    // Fails if `cancelAll` spares leases: without the lease release in `cancelAll` the
    // viewer close leaks every holder (the pages' own shares never free — only the
    // committed holder's release returns the player).
    @Test("cancel all releases leases")
    func cancelAllReleasesLeases() {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory, maxPlayers: 5)
        let driver = StoryPlanDriver(prefetch: FakeStoryPrefetch())

        update(driver, pool, 5, at: 2)
        #expect(!pool.heldKeys().isEmpty)
        driver.cancelAll()

        #expect(pool.heldKeys().isEmpty)
    }
}
