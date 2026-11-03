import AVFoundation
import Foundation
import Testing

@testable import DigiaEngage

// File URLs keep the suite hermetic: `AVPlayerItem` starts resolving its asset as soon as it
// becomes the current item, so remote URLs would fire real (failing) network requests. The pool
// only reads the URL back, never the bytes.
private func leaseTestURL(_ name: String) -> URL {
    URL(string: "file:///tmp/media-lease-test/\(name)")!
}

private func leaseTestURLString(_ name: String) -> String {
    leaseTestURL(name).absoluteString
}

private final class LeaseFakeFactory: PlayerFactory {
    var creates = 0
    func makePlayer() -> AVQueuePlayer {
        creates += 1
        return AVQueuePlayer()
    }
}

@Suite("PlayerLease", .tags(.media, .unit))
struct PlayerLeaseTests {
    private func pool(
        factory: LeaseFakeFactory,
        maxPlayers: Int = 2,
        onEvict: ((String) -> Void)? = nil
    ) -> VideoPlayerPool {
        VideoPlayerPool(factory: factory, maxPlayers: maxPlayers, onEvict: onEvict)
    }

    // Fails if release frees twice: without the `released` flag the second release
    // re-frees the key, and the next obtain rebuilds instead of reusing.
    @Test("release is idempotent and frees exactly once")
    func releaseIsIdempotent() throws {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory)
        let lease = try #require(pool.obtainLease(
            key: "a", url: leaseTestURLString("one.mp4"), priority: .onScreen))

        lease.release()
        #expect(pool.heldKeys().isEmpty)
        lease.release()
        #expect(pool.heldKeys().isEmpty)

        let again = try #require(pool.obtainLease(
            key: "b", url: leaseTestURLString("two.mp4"), priority: .onScreen))
        #expect(factory.creates == 1)
        #expect(again.player === lease.player)
        again.release()
    }

    // Fails if a share frees: without the `!shared` guard the share's release gives
    // the holder back, and the committed holder keeps driving a freed player.
    @Test("a second obtain of a held key shares and only the holder frees")
    func shareRule() throws {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory)
        let holder = try #require(pool.obtainLease(
            key: "a", url: leaseTestURLString("clip.mp4"), priority: .onScreen))
        let share = try #require(pool.obtainLease(
            key: "a", url: leaseTestURLString("clip.mp4"), priority: .onScreen))

        #expect(holder.shared == false)
        #expect(share.shared == true)
        #expect(share.player === holder.player)

        share.release()
        #expect(pool.heldKeys() == ["a"])

        holder.release()
        #expect(pool.heldKeys().isEmpty)
    }

    // Fails if a post-eviction release frees the wrong holder: without the
    // `giveBackIfHeldBy` identity check the evicted lease's release gives back
    // the key the pool has since re-issued.
    @Test("a post-eviction release is a no-op")
    func postEvictionReleaseIsNoOp() throws {
        let factory = LeaseFakeFactory()
        var evicted: [String] = []
        let pool = pool(factory: factory, onEvict: { evicted.append($0) })
        let victim = try #require(pool.obtainLease(
            key: "a", url: leaseTestURLString("a.mp4"), priority: .railThumb))
        _ = try #require(pool.obtainLease(
            key: "b", url: leaseTestURLString("b.mp4"), priority: .railThumb))

        let newcomer = try #require(pool.obtainLease(
            key: "c", url: leaseTestURLString("c.mp4"), priority: .onScreen))
        #expect(evicted == ["a"])

        // Free a slot through a legitimate release, then re-issue the evicted
        // key: the stale lease now faces a live holder with another player.
        newcomer.release()
        let reissued = try #require(pool.obtainLease(
            key: "a", url: leaseTestURLString("a2.mp4"), priority: .railThumb))
        #expect(reissued.player !== victim.player)

        victim.release()
        #expect(pool.heldKeys() == ["a", "b"])
        let share = try #require(pool.obtainLease(
            key: "a", url: leaseTestURLString("a2.mp4"), priority: .railThumb))
        #expect(share.player === reissued.player)
        share.release()
        reissued.release()
    }

    // Fails if a stale release steals a re-borrowed key: without the identity
    // check a lease freed by teardown keeps freeing the key it no longer owns.
    @Test("a stale release after a re-borrow keeps the new holder")
    func staleReleaseAfterReborrowKeepsTheNewHolder() throws {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory)
        let stale = try #require(pool.obtainLease(
            key: "a", url: leaseTestURLString("one.mp4"), priority: .onScreen))

        pool.release()
        let current = try #require(pool.obtainLease(
            key: "a", url: leaseTestURLString("two.mp4"), priority: .onScreen))

        stale.release()
        #expect(pool.heldKeys() == ["a"])
        #expect(current.player.currentItem != nil)
        current.release()
    }

    // Fails if a refused borrow registers or builds: without the rank gate the
    // railThumb obtain evicts the on-screen holder instead of degrading.
    @Test("a refused borrow returns nil and registers nothing")
    func refusedBorrowReturnsNil() throws {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory, maxPlayers: 1)
        _ = try #require(pool.obtainLease(
            key: "screen", url: leaseTestURLString("screen.mp4"), priority: .onScreen))
        var causes: [String] = []

        let refused = pool.obtainLease(
            key: "thumb", url: leaseTestURLString("thumb.mp4"), priority: .railThumb,
            onFailure: { causes.append($0) })

        #expect(refused == nil)
        #expect(causes.isEmpty)
        #expect(factory.creates == 1)
        #expect(pool.heldKeys() == ["screen"])
    }

    // Fails if an unusable URL registers a holder: without the `mediaUsableURL`
    // guard the pool holds a key whose player can never play.
    @Test("an unusable url reports invalid_url and registers nothing")
    func invalidURLReportsAndRegistersNothing() {
        let factory = LeaseFakeFactory()
        let pool = pool(factory: factory)
        var causes: [String] = []

        let lease = pool.obtainLease(
            key: "a", url: "{{campaign.video}}", priority: .onScreen,
            onFailure: { causes.append($0) })

        #expect(lease == nil)
        #expect(causes == ["invalid_url"])
        #expect(factory.creates == 0)
        #expect(pool.heldKeys().isEmpty)
    }

    // Fails if the no-SDK path owns players outside the lease: without the
    // single-slot pool a keyless host would build an unpooled player per view.
    @Test("the no-sdk pool serves the same lease path with a single slot")
    func noSdkPoolLeasePath() throws {
        NoSdkVideoPool.resetForTesting()
        defer { NoSdkVideoPool.resetForTesting() }
        let factory = LeaseFakeFactory()
        let fallback = NoSdkVideoPool.shared(factory: factory)

        let first = try #require(fallback.obtainLease(
            key: "a", url: leaseTestURLString("one.mp4"), priority: .railThumb))
        #expect(first.shared == false)
        let refused = fallback.obtainLease(
            key: "b", url: leaseTestURLString("two.mp4"), priority: .railThumb)
        #expect(refused == nil)

        first.release()
        let second = try #require(fallback.obtainLease(
            key: "b", url: leaseTestURLString("two.mp4"), priority: .railThumb))
        #expect(factory.creates == 1)
        second.release()
    }
}
