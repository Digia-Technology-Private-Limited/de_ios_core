import AVFoundation
import Foundation
import Testing

@testable import DigiaEngage

// File URLs: `AVPlayerItem` starts resolving its asset as soon as it becomes
// the current item, so remote URLs would fire real (failing) network requests
// from unit tests. File URLs keep the suite hermetic; the pool only reads the
// URL back through `(asset as? AVURLAsset)?.url`.
private func mediaURL(_ name: String) -> URL { URL(string: "file:///tmp/media-test/\(name)")! }

private func itemURL(of player: AVPlayer?) -> URL? {
    (player?.currentItem?.asset as? AVURLAsset)?.url
}

private final class FakePlayerFactory: PlayerFactory {
    var creates = 0
    func makePlayer() -> AVQueuePlayer {
        creates += 1
        return AVQueuePlayer()
    }
}

@MainActor
@Suite("VideoPlayerPool", .tags(.media, .unit))
struct VideoPlayerPoolTests {
    private func pool(
        factory: FakePlayerFactory,
        maxPlayers: Int = 2,
        onEvict: ((String) -> Void)? = nil
    ) -> VideoPlayerPool {
        VideoPlayerPool(factory: factory, maxPlayers: maxPlayers, onEvict: onEvict)
    }

    // Fails if the pool builds eagerly: a `makePlayer()` in the initializer.
    @Test("creates no player until the first obtain")
    func createsNoPlayerUntilTheFirstObtain() {
        let factory = FakePlayerFactory()
        _ = pool(factory: factory)

        #expect(factory.creates == 0)
    }

    // Fails if a freed player is not reused: without the `free.popLast()`
    // branch the second obtain creates instead of re-pointing.
    @Test("reuses a free player by re-pointing")
    func reusesAFreePlayerByRepointing() throws {
        let factory = FakePlayerFactory()
        let pool = pool(factory: factory)
        let first = pool.obtain(key: "a", url: mediaURL("one.mp4"), priority: .onScreen)
        let oldItem = first?.currentItem
        pool.giveBack(key: "a")

        let second = pool.obtain(key: "b", url: mediaURL("two.mp4"), priority: .onScreen)

        #expect(factory.creates == 1)
        #expect(second === first)
        #expect(second?.currentItem !== oldItem)
        #expect(itemURL(of: second) == mediaURL("two.mp4"))
    }

    // Fails if eviction drops the wrong end or ignores rank: without the gated
    // `evictableTailLocked` + `tail.priority > priority` check, an
    // unconditional tail release lets a VIEWER_NEXT obtain kill the ON_SCREEN
    // holder (and the callback never fires).
    @Test("a full pool evicts the lowest priority")
    func aFullPoolEvictsTheLowestPriority() throws {
        let factory = FakePlayerFactory()
        var evicted: [String] = []
        let pool = pool(factory: factory, onEvict: { evicted.append($0) })
        let screen = try #require(pool.obtain(key: "a", url: mediaURL("a.mp4"), priority: .onScreen))
        let thumb = try #require(pool.obtain(key: "b", url: mediaURL("b.mp4"), priority: .railThumb))

        let next = try #require(pool.obtain(key: "c", url: mediaURL("c.mp4"), priority: .viewerNext))

        #expect(thumb.currentItem == nil)
        #expect(screen.currentItem != nil)
        #expect(next !== thumb)
        #expect(evicted == ["b"])
        #expect(itemURL(of: next) == mediaURL("c.mp4"))
    }

    // Fails if a lower-ranked newcomer takes a holder with it: without the
    // rank gate the RAIL_THUMB obtain evicts (and the callback fires); with it
    // the newcomer gets nil — its still — and nothing is created or released.
    @Test("a newcomer that outranks nothing gets no player and evicts nothing")
    func aNewcomerThatOutranksNothingGetsNoPlayerAndEvictsNothing() throws {
        let factory = FakePlayerFactory()
        var evicted: [String] = []
        let pool = pool(factory: factory, onEvict: { evicted.append($0) })
        _ = try #require(pool.obtain(key: "a", url: mediaURL("a.mp4"), priority: .onScreen))
        _ = try #require(pool.obtain(key: "b", url: mediaURL("b.mp4"), priority: .viewerNext))

        let refused = pool.obtain(key: "c", url: mediaURL("c.mp4"), priority: .railThumb)

        #expect(refused == nil)
        #expect(factory.creates == 2)
        #expect(evicted.isEmpty)
        #expect(pool.heldKeys() == ["a", "b"])
    }

    // Fails if ties evict the wrong end: evicting the most-recently-obtained
    // holder instead of the `a.seq < b.seq` least-recent contract.
    @Test("ties evict the least recently obtained")
    func tiesEvictTheLeastRecentlyObtained() throws {
        let factory = FakePlayerFactory()
        var evicted: [String] = []
        let pool = pool(factory: factory, onEvict: { evicted.append($0) })
        let stale = try #require(pool.obtain(key: "a", url: mediaURL("a.mp4"), priority: .viewerNext))
        let fresh = try #require(pool.obtain(key: "b", url: mediaURL("b.mp4"), priority: .viewerNext))

        let current = try #require(pool.obtain(key: "c", url: mediaURL("c.mp4"), priority: .onScreen))

        #expect(stale.currentItem == nil)
        #expect(fresh.currentItem != nil)
        #expect(evicted == ["a"])
        #expect(factory.creates == 3)
        #expect(current !== stale)
    }

    // Fails if the same key always creates: without the `holders[key]`
    // handover the second obtain mints a second player for the same key.
    // Fails too if the same URL re-points: `first.currentItem` identity proves
    // the `existing.url != url` skip (gapless, Android R-P3-01).
    @Test("the same key and url returns the same object without re-pointing")
    func theSameKeyAndUrlReturnsTheSameObject() throws {
        let factory = FakePlayerFactory()
        let pool = pool(factory: factory)

        let first = try #require(pool.obtain(key: "a", url: mediaURL("a.mp4"), priority: .onScreen))
        let second = try #require(pool.obtain(key: "a", url: mediaURL("a.mp4"), priority: .viewerNext))

        #expect(second === first)
        #expect(factory.creates == 1)
        #expect(second.currentItem === first.currentItem)
        #expect(itemURL(of: second) == mediaURL("a.mp4"))
    }

    // Fails if a new URL on a held key mints instead of re-pointing — or if the
    // re-point is skipped: without `repointLocked` the player keeps the old item.
    @Test("a new url on the same key re-points the same object")
    func aNewUrlOnTheSameKeyRepointsTheSameObject() throws {
        let factory = FakePlayerFactory()
        let pool = pool(factory: factory)
        let first = try #require(pool.obtain(key: "a", url: mediaURL("one.mp4"), priority: .onScreen))

        let second = try #require(pool.obtain(key: "a", url: mediaURL("two.mp4"), priority: .onScreen))

        #expect(second === first)
        #expect(factory.creates == 1)
        #expect(itemURL(of: second) == mediaURL("two.mp4"))
    }

    // Fails if a missing key throws: e.g. a force-unwrap of
    // `holders.removeValue(forKey:)` in giveBack.
    @Test("giveBack of a missing key is a silent no-op")
    func giveBackOfAMissingKeyIsASilentNoOp() {
        let factory = FakePlayerFactory()
        let pool = pool(factory: factory)

        pool.giveBack(key: "never-held")

        #expect(factory.creates == 0)
        #expect(pool.heldKeys().isEmpty)
    }

    // Fails if release spares freed players: without detaching `free`, the
    // given-back player keeps its item after release; fails too if release
    // forgets `holders.removeAll()`, since the next obtain would hand over a
    // detached instance instead of creating.
    @Test("release detaches all and later giveBacks are silent")
    func releaseReleasesAllAndLaterGiveBacksAreSilent() throws {
        let factory = FakePlayerFactory()
        let pool = pool(factory: factory)
        let held = try #require(pool.obtain(key: "a", url: mediaURL("a.mp4"), priority: .onScreen))
        let freed = try #require(pool.obtain(key: "b", url: mediaURL("b.mp4"), priority: .onScreen))
        pool.giveBack(key: "b")

        pool.release()

        #expect(held.currentItem == nil)
        #expect(freed.currentItem == nil)
        #expect(pool.heldKeys().isEmpty)
        pool.giveBack(key: "a")
        let fresh = try #require(pool.obtain(key: "c", url: mediaURL("c.mp4"), priority: .onScreen))
        #expect(fresh !== held && fresh !== freed)
        #expect(factory.creates == 3)
    }

    // Retargeted (Android R-P2-06): the 2/3/4 sizes are TODO placeholders, so
    // nothing pins them. What is pinned is the classifier contract — unknown
    // degrades to MID, each threshold lands its bucket. Fails if the
    // `physicalMemoryBytes == 0` guard moves (0 would classify LOW) or a
    // threshold shifts a boundary.
    @Test("deviceClassFor degrades unknown and lands each boundary")
    func deviceClassForDegradesUnknownAndLandsBoundaries() {
        let gib = UInt64(1_024 * 1_024 * 1_024)
        #expect(deviceClassFor(physicalMemoryBytes: 0) == .mid)
        #expect(deviceClassFor(physicalMemoryBytes: 1) == .low)
        #expect(deviceClassFor(physicalMemoryBytes: 4 * gib - 1) == .low)
        #expect(deviceClassFor(physicalMemoryBytes: 4 * gib) == .mid)
        #expect(deviceClassFor(physicalMemoryBytes: 7 * gib - 1) == .mid)
        #expect(deviceClassFor(physicalMemoryBytes: 7 * gib) == .high)
        #expect(deviceClassFor(physicalMemoryBytes: .max) == .high)
    }

    // Fails if the default factory stops vending a queue player: the
    // `AVQueuePlayer()` line in `DefaultPlayerFactory.makePlayer` (the entry
    // needs a queue player so a borrower can attach an `AVPlayerLooper`).
    @Test("the default factory vends a queue player")
    func theDefaultFactoryVendsAQueuePlayer() {
        #expect(DefaultPlayerFactory().makePlayer() is AVQueuePlayer)
    }

    // Fails if the loop flag is lost or the looper leaks across borrows:
    // `setLooping` must set the flag, a same-key re-point must preserve it
    // (the `repointLocked` looper rebuild), and `giveBack` must clear it so a
    // pooled player never loops silently in the background.
    @Test("looping is per-borrow and cleared on giveBack")
    func loopingIsPerBorrowAndClearedOnGiveBack() throws {
        let factory = FakePlayerFactory()
        let pool = pool(factory: factory)
        _ = try #require(pool.obtain(key: "a", url: mediaURL("a.mp4"), priority: .onScreen))

        pool.setLooping(true, forKey: "a")
        #expect(pool.isLooping(key: "a"))

        _ = try #require(pool.obtain(key: "a", url: mediaURL("b.mp4"), priority: .onScreen))
        #expect(pool.isLooping(key: "a"))

        pool.giveBack(key: "a")
        #expect(!pool.isLooping(key: "a"))
    }

    // Fails if setLooping throws on a missing key: e.g. a force-unwrap of
    // `holders[key]` instead of the silent-`guard` no-op.
    @Test("setLooping on a missing key is a silent no-op")
    func setLoopingOnAMissingKeyIsASilentNoOp() {
        let factory = FakePlayerFactory()
        let pool = pool(factory: factory)

        pool.setLooping(true, forKey: "never-held")

        #expect(factory.creates == 0)
        #expect(!pool.isLooping(key: "never-held"))
    }
}

@MainActor
@Suite("SDKServices video pool wiring", .tags(.media, .unit))
struct SDKServicesPoolWiringTests {
    private struct NeverSlow: SlowNetworkSource {
        var isSlow: Bool { false }
    }

    private func makeServices(factory: FakePlayerFactory, maxPlayers: Int) -> SDKServices {
        let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)
        return SDKServices(
            config: DigiaConfig(apiKey: "test_key"),
            storage: storage,
            networkClient: MockNetworkClient(),
            analyticsQueue: MemoryAnalyticsQueue(),
            playerFactory: factory,
            maxPoolSize: maxPlayers,
            slowNetworkSource: NeverSlow()
        )
    }

    // Fails if the pool is not injected per instance, or the slow source is
    // not wired: the `videoPlayerPool` / `slowNetworkSource` lines in
    // `SDKServices.init`.
    @Test("services own an injected pool and slow source")
    func servicesOwnAnInjectedPoolAndSlowSource() throws {
        let factory = FakePlayerFactory()
        let services = makeServices(factory: factory, maxPlayers: 1)

        let first = try #require(services.videoPlayerPool.obtain(
            key: "a", url: mediaURL("a.mp4"), priority: .onScreen
        ))
        #expect(services.videoPlayerPool.obtain(
            key: "b", url: mediaURL("b.mp4"), priority: .railThumb
        ) == nil)
        #expect(first.currentItem != nil)
        #expect(services.slowNetworkSource.isSlow == false)
    }

    // Fails if teardown forgets the pool: without the
    // `videoPlayerPool.release()` line in `tearDown`, the held player keeps its
    // item and the next obtain re-serves the detached instance.
    @Test("teardown releases the pool")
    func teardownReleasesThePool() throws {
        let factory = FakePlayerFactory()
        let services = makeServices(factory: factory, maxPlayers: 1)
        let held = try #require(services.videoPlayerPool.obtain(
            key: "a", url: mediaURL("a.mp4"), priority: .onScreen
        ))

        services.tearDown()

        #expect(held.currentItem == nil)
        let fresh = try #require(services.videoPlayerPool.obtain(
            key: "b", url: mediaURL("b.mp4"), priority: .onScreen
        ))
        #expect(fresh !== held)
        #expect(factory.creates == 2)
    }
}
