import AVFoundation
import Foundation
import Testing

@testable import DigiaEngage

// The rail-to-viewer handover (T10): tapping a playing thumbnail reuses the SAME pool player in
// the viewer (same key + same URL), reset to the start and unmuted, with no frame gap. Driven
// through `MediaVideoState` (the same borrow both views use) with the real pool and a fake
// factory — no network, no render host.

private final class HandoverFakeFactory: PlayerFactory {
    var creates = 0
    func makePlayer() -> AVQueuePlayer {
        creates += 1
        return AVQueuePlayer()
    }
}

private func handoverPool(factory: HandoverFakeFactory, maxPlayers: Int = 2) -> VideoPlayerPool {
    VideoPlayerPool(factory: factory, maxPlayers: maxPlayers)
}

private func handoverFileURL(_ name: String) -> URL {
    URL(string: "file:///tmp/story-handover-test/\(UUID().uuidString)/\(name)")!
}

@MainActor
private func handoverCoordinator(
    pool: VideoPlayerPool,
    key: String,
    priority: PoolPriority,
    url: URL,
    muted: Bool,
    startMs: Int = 0
) -> MediaVideoState {
    let state = MediaVideoState(
        spec: VideoSpec(
            url: url.absoluteString,
            playback: Playback(autoplay: true, muted: muted, startMs: startMs)
        ),
        playing: true,
        keepAliveKey: key,
        poolPriority: priority,
        pool: pool,
        resourceLoader: MediaResourceLoader()
    )
    state.appear(campaignKey: nil)
    return state
}

@Suite("StoryHandover", .tags(.media, .unit, .inline))
@MainActor
struct StoryHandoverTests {
    // Fails if the tap hands over a different player: the same key + same URL must return the
    // identical instance from `VideoPlayerPool.obtain` (no re-point, no re-buffer — the
    // borrowed frame survives), with `takeOver` applying the viewer's unmuted spec on it.
    // Captures the item BEFORE the viewer appears: a re-point would install a new one.
    @Test("tapping a playing thumbnail reuses its player from the start unmuted with no gap")
    func tapReusesThePlayingThumbnailPlayer() {
        let factory = HandoverFakeFactory()
        let pool = handoverPool(factory: factory)
        let url = handoverFileURL("clip.mp4")
        let key = "test/story-0"

        // The rail's playing thumbnail: muted, window start.
        let thumb = handoverCoordinator(
            pool: pool, key: key, priority: .railThumb, url: url, muted: true, startMs: 5_000)
        let thumbPlayer = thumb.activePlayer
        let thumbItem = thumbPlayer?.currentItem
        #expect(thumbPlayer != nil)
        #expect(thumbItem != nil)
        #expect(thumbPlayer?.isMuted == true)

        // The tap: the viewer borrows under the same key and URL, unmuted, from 0.
        let viewer = handoverCoordinator(
            pool: pool, key: key, priority: .onScreen, url: url, muted: false)
        let viewerPlayer = viewer.activePlayer
        #expect(viewerPlayer != nil)
        #expect(viewerPlayer === thumbPlayer)
        #expect(viewerPlayer?.currentItem === thumbItem)
        #expect(viewerPlayer?.isMuted == false)
        #expect(factory.creates == 1)

        thumb.disappear()
        viewer.disappear()
        #expect(pool.heldKeys().isEmpty)
    }

    // Fails if a different story's player is handed over: `obtain` keys on the full key, so a
    // neighbouring card never donates its instance.
    @Test("a neighbouring card never donates its player")
    func neighbouringCardNeverDonatesItsPlayer() {
        let factory = HandoverFakeFactory()
        let pool = handoverPool(factory: factory)
        let first = handoverCoordinator(
            pool: pool, key: "test/story-0", priority: .railThumb,
            url: handoverFileURL("a.mp4"), muted: true)
        let second = handoverCoordinator(
            pool: pool, key: "test/story-1", priority: .railThumb,
            url: handoverFileURL("b.mp4"), muted: true)

        #expect(first.activePlayer != nil)
        #expect(second.activePlayer != nil)
        #expect(first.activePlayer !== second.activePlayer)
        #expect(pool.heldKeys() == ["test/story-0", "test/story-1"])

        first.disappear()
        second.disappear()
    }

    // Fails if a second borrower under the same key gets a different instance: the PIP-style
    // takeover (same key + same URL, its own priority) must share the committed holder and
    // re-apply its spec on it — unmuted here. Driven entirely through `MediaVideoState`
    // (the same borrow every story view uses), with the real pool and a fake factory.
    // Break-once: the pool's existing-key branch (`borrow(key:url:priority:)` returning the
    // committed instance) or the take-over's mute line.
    @Test("a PIP takeover shares the viewer instance through state")
    func pipTakeoverSharesTheViewerInstance() {
        let factory = HandoverFakeFactory()
        let pool = handoverPool(factory: factory)
        let url = handoverFileURL("clip.mp4")
        let key = "test/story-0"

        let thumb = handoverCoordinator(
            pool: pool, key: key, priority: .railThumb, url: url, muted: true, startMs: 5_000)
        let thumbPlayer = thumb.activePlayer
        #expect(thumbPlayer != nil)

        let viewer = handoverCoordinator(
            pool: pool, key: key, priority: .onScreen, url: url, muted: false)
        let viewerPlayer = viewer.activePlayer
        #expect(viewerPlayer === thumbPlayer)
        #expect(viewerPlayer?.isMuted == false)

        // The PIP takeover: same key + same URL at its own priority — the same instance,
        // with its own spec re-applied on it.
        let pip = handoverCoordinator(
            pool: pool, key: key, priority: .viewerNext, url: url, muted: false)
        #expect(pip.activePlayer === viewerPlayer)
        #expect(pip.activePlayer?.isMuted == false)
        #expect(factory.creates == 1)

        thumb.disappear()
        viewer.disappear()
        pip.disappear()
        #expect(pool.heldKeys().isEmpty)
    }

    // Fails if a handed-over borrow is freed by its own dispose: without the
    // `borrowHandedOver` guard in `disappear()` the rail card freeing its committed lease
    // pauses the viewer mid-frame. The key stays held after both disposes — the rail's
    // remount re-takes ownership under the same key (same instance, window re-applied);
    // pool eviction bounds the holder meanwhile. Break-once: the `if !borrowHandedOver()`
    // guard in `MediaVideoState.disappear()`.
    @Test("a handed-over borrow survives its own dispose")
    func handedOverBorrowSurvivesItsOwnDispose() {
        let factory = HandoverFakeFactory()
        let pool = handoverPool(factory: factory)
        let url = handoverFileURL("clip.mp4")
        let key = "test/story-0"

        let rail = MediaVideoState(
            spec: VideoSpec(url: url.absoluteString, playback: Playback(autoplay: true, muted: true)),
            playing: true,
            keepAliveKey: key,
            poolPriority: .railThumb,
            pool: pool,
            resourceLoader: MediaResourceLoader(),
            borrowHandedOver: { true }
        )
        rail.appear(campaignKey: nil)
        let railPlayer = rail.activePlayer
        #expect(railPlayer != nil)

        let viewer = handoverCoordinator(
            pool: pool, key: key, priority: .onScreen, url: url, muted: false)
        #expect(viewer.activePlayer === railPlayer)

        rail.disappear()
        #expect(pool.heldKeys() == [key])
        #expect(viewer.activePlayer === railPlayer)

        viewer.disappear()
        #expect(pool.heldKeys() == [key])
    }
}
