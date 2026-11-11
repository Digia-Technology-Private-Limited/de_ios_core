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

/// One story window case: the stories a viewer opens on, and what it must then hold and warm.
struct WindowCase: CustomTestStringConvertible, Sendable {
    let name: String
    let types: [StoryMediaType]
    let start: Int
    let slow: Bool
    /// Stories holding a pool player, at their rank.
    let players: [Int: PoolPriority]
    /// Stories whose first bytes are warmed with no player.
    let firstBytes: Set<Int>
    var testDescription: String { name }
}

let storyWindowCases: [WindowCase] = [
    WindowCase(
        name: "open at the first story: its player, the next one's, the first bytes two ahead",
        types: Array(repeating: .video, count: 4), start: 0, slow: false,
        players: [0: .viewerPage, 1: .viewerNext], firstBytes: [2]),
    WindowCase(
        name: "open in the middle: players either side, first bytes two either side",
        types: Array(repeating: .video, count: 5), start: 2, slow: false,
        players: [2: .viewerPage, 3: .viewerNext, 1: .viewerPrev], firstBytes: [4, 0]),
    WindowCase(
        name: "open on the last story: only backward",
        types: Array(repeating: .video, count: 5), start: 4, slow: false,
        players: [4: .viewerPage, 3: .viewerPrev], firstBytes: [2]),
    WindowCase(
        name: "open on the second story: its own window, with the first one behind it",
        types: Array(repeating: .video, count: 5), start: 1, slow: false,
        players: [1: .viewerPage, 2: .viewerNext, 0: .viewerPrev], firstBytes: [3]),
    WindowCase(
        name: "a slow network: the current player and the next story's first bytes only",
        types: Array(repeating: .video, count: 5), start: 2, slow: true,
        players: [2: .viewerPage], firstBytes: [3]),
]


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

    // Guards the `StoryVideoSurface(... priority: .onScreen ...)` in `StoryThumbnailVideo` (T3, OD-24): a
    // rail video tile plays through `MediaVideo`, on the pool, at a Stage-2 rank like any video on screen.
    @Test("a rail video tile plays through MediaVideo on the pool at the on-screen rank")
    func railTileRoutesThroughMediaVideoOnThePool() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("rail-tile.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let pool = MediaServices.current.videoPool
        let item = StoryItemConfig(type: .video, url: video.absoluteString, duration: nil)

        let window = MediaStage.mount(StoryRail(
            items: [item], cardWidth: 120, cardHeight: 120, cardCornerRadius: 8,
            cardSpacing: 8, overlayOpen: false, onOpen: { _, _ in }))
        defer { ComponentTestHost.unmount(window) }

        let key = storyPoolKey(namespace: MediaStage.campaign, index: 0)
        #expect(await waitUntilMedia { pool.priority(of: key) == .onScreen })
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
        #expect(await waitUntilMedia { pool.priority(of: keySecond) == .viewerPage }, "the viewer moved on")
        ComponentTestHost.drainRunLoop(for: 0.2)

        #expect(pool.heldPlayer(for: keyFirst) === player, "page 0's player is kept for a swipe back")
        #expect(pool.heldPlayer(for: keySecond) != nil)
    }

    // MARK: The download window, seen through the viewer

    private func serve(
        _ types: [StoryMediaType], holding: Set<Int> = [], status: [Int: Int] = [:]
    ) throws -> (items: [StoryItemConfig], urls: [URL]) {
        var items: [StoryItemConfig] = [], urls: [URL] = []
        for (index, type) in types.enumerated() {
            let url = MediaOrigin.url("window-\(index).\(type == .video ? "mp4" : "png")")
            let body = type == .video ? try testkitAsset("movie.mp4") : solidPNG(.red)
            MediaOrigin.set(.status(status[index] ?? 200, body), for: url, held: holding.contains(index))
            items.append(StoryItemConfig(type: type, url: url.absoluteString, duration: 60_000))
            urls.append(url)
        }
        return (items, urls)
    }

    private func openViewer(_ items: [StoryItemConfig], at start: Int, slow: any SlowNetworkSource) -> UIWindow {
        MediaStage.mount(
            StoryViewer(entry: StoryViewerEntry(
                stories: items, startIndex: start, restartOnCompleted: false, startMuted: true,
                defaultDurationMs: 60_000, reporter: SilentReporter(), onDismiss: {}
            )) { _ in EmptyView() }
            .environment(\.storySlowNetwork, slow))
    }

    private func poolKey(_ index: Int) -> String { storyPoolKey(namespace: MediaStage.campaign, index: index) }

    private func ranks(_ pool: VideoPlayerPool, of count: Int) -> [Int: PoolPriority] {
        (0 ..< count).reduce(into: [:]) { ranks, index in ranks[index] = pool.priority(of: poolKey(index)) }
            .compactMapValues { $0 }
    }

    /// What the origin was asked for, by story: the `Range` of each request ("whole" with none).
    private func asked(_ urls: [URL]) -> [Int: [String]] {
        urls.enumerated().reduce(into: [:]) { asked, entry in
            let ranges = MediaOrigin.requests(for: entry.element).map { $0.range ?? "whole" }
            if !ranges.isEmpty { asked[entry.offset] = ranges }
        }
    }

    private static let firstBytesRange = "bytes=0-\(storyFirstBytes - 1)"

    /// The warm asked from byte 0 for the first-bytes window and nothing past it. (A video shorter
    /// than the window gets a second, tail request for the rest of the window.)
    private static func askedOnlyForFirstBytes(_ ranges: [String]?) -> Bool {
        guard let ranges, ranges.first == firstBytesRange else { return false }
        return ranges.allSatisfy { $0.hasSuffix("-\(storyFirstBytes - 1)") }
    }

    // Guards `if !firstFrameShown { return actions }` in `StoryDownloadPlan.plan`: a story whose
    // first frame has not shown holds its own player and nothing else, neither a neighbour's player
    // nor a byte of a neighbour, until the frame arrives.
    @Test("a story opens on its own player alone until its first frame shows, then the window grows")
    func coldStartPlansOnlyTheCurrentPlayer() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = MediaServices.current.videoPool
        let (items, urls) = try serve([.video, .video, .video, .video], holding: [0])

        let window = openViewer(items, at: 0, slow: FlippableSlowNetwork())
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: urls[0]).isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.6)

        #expect(ranks(pool, of: 4) == [0: .viewerPage])
        #expect(asked(urls).keys.sorted() == [0], "nothing asked for a neighbour: \(asked(urls))")

        MediaOrigin.release(urls[0])
        #expect(await waitUntilMedia { pool.priority(of: poolKey(1)) == .viewerNext }, "the first frame opens the window")
    }

    // Guards the window actions in `StoryDownloadPlan.plan`: the forward `firstBytes(n+2)`, the last
    // story's backward `firstBytes(n-2)`, the general branch's `player(n-1)` and the early
    // `slowNetwork` return. Seen as the ranks the pool holds and the byte ranges the origin serves.
    @Test("the viewer holds players and warms bytes by the window rules", arguments: storyWindowCases)
    func viewerWindowShapes(_ shape: WindowCase) async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = MediaServices.current.videoPool
        let (items, urls) = try serve(shape.types)
        let slow = FlippableSlowNetwork()
        slow.isSlow = shape.slow

        let window = openViewer(items, at: shape.start, slow: slow)
        defer { ComponentTestHost.unmount(window) }
        let warmed = shape.firstBytes.sorted()
        #expect(await waitUntilMedia(timeout: 5) {
            ranks(pool, of: items.count) == shape.players
                && warmed.allSatisfy { !MediaOrigin.requests(for: urls[$0]).isEmpty }
        }, "the window opened: \(ranks(pool, of: items.count)) \(asked(urls))")
        ComponentTestHost.drainRunLoop(for: 0.4)

        #expect(ranks(pool, of: items.count) == shape.players)
        let asked = asked(urls)
        #expect(Set(asked.keys) == Set(shape.players.keys).union(shape.firstBytes), "nothing else is asked for: \(asked)")
        for index in shape.firstBytes {
            #expect(Self.askedOnlyForFirstBytes(asked[index]), "story \(index): first bytes only, no whole file: \(asked[index] ?? [])")
        }
    }

    // Guards `stories[index].isVideo ? .player(...) : .wholeFile(...)` in
    // `StoryDownloadPlan.playerOrWholeFile`: an image never takes a player, and its whole file (no
    // Range) is warmed, while the video after it gets first bytes.
    @Test("an image in the window is warmed whole and never takes a player")
    func imagesAreWarmedWholeWithoutAPlayer() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = MediaServices.current.videoPool
        let (items, urls) = try serve([.video, .image, .video])

        let window = openViewer(items, at: 0, slow: FlippableSlowNetwork())
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia(timeout: 5) {
            !MediaOrigin.requests(for: urls[1]).isEmpty && !MediaOrigin.requests(for: urls[2]).isEmpty
        })
        ComponentTestHost.drainRunLoop(for: 0.4)

        #expect(ranks(pool, of: 3) == [0: .viewerPage], "the image has no player")
        #expect(asked(urls)[1] == ["whole"])
        #expect(Self.askedOnlyForFirstBytes(asked(urls)[2]), "\(asked(urls)[2] ?? [])")
    }

    /// Opens a three-story viewer on a source that measures, with the third story's first bytes
    /// held at the origin for `seconds` (the time one warm takes), and answers whether the next
    /// story's player was still held afterwards.
    private func nextPlayerKept(
        afterAWarmOf seconds: TimeInterval, third status: Int = 200, seeding: (URL) async -> Void = { _ in }
    ) async throws -> Bool {
        install()
        defer { MediaOrigin.end() }
        let pool = MediaServices.current.videoPool
        let (items, urls) = try serve([.video, .video, .video], holding: [2], status: [2: status])
        await seeding(urls[1])

        let window = openViewer(items, at: 0, slow: PathSlowNetworkSource())
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { pool.priority(of: poolKey(1)) == .viewerNext }, "fast until measured otherwise")
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: urls[2]).isEmpty })
        _ = await waitUntilMedia(timeout: seconds) { false }
        MediaOrigin.release(urls[2])
        _ = await waitUntilMedia(timeout: 1.0) { pool.priority(of: poolKey(1)) == nil }
        return pool.priority(of: poolKey(1)) == .viewerNext
    }

    // Guards `throughput.note(bytes:elapsed:)` in `PathSlowNetworkSource.noteWarm` and the
    // `measuredKbps < slowDownstreamKbps` comparison in `slowNetworkFor`: a warm of the movie's
    // 318 465 bytes that takes 2.6 s is 980 kbps, so the viewer drops the next story's player.
    @Test("a first-bytes warm that crawls turns the network slow and the next player is let go")
    func slowWarmTurnsTheNetworkSlow() async throws {
        #expect(try await nextPlayerKept(afterAWarmOf: 2.6) == false)
    }

    // Guards `Double(bytes) * 8 / 1_000 / elapsed` in `SlowNetworkThroughput.note`: 318 465 bytes in
    // 0.8 s is 3.2 Mbps, a fast link (read as bytes instead of bits it would be 398 kbps, slow).
    @Test("a first-bytes warm at a few Mbps leaves the network fast and the next player held")
    func fastWarmKeepsTheNetworkFast() async throws {
        #expect(try await nextPlayerKept(afterAWarmOf: 0.8) == true)
    }

    // Guards `guard bytes > 0, ...` in `SlowNetworkThroughput.note`: a warm that failed delivers
    // 0 bytes (read as 0 kbps it would turn the network slow), though it took long enough to time.
    @Test("a warm that fails measures nothing, so the network stays fast")
    func failedWarmDoesNotVote() async throws {
        #expect(try await nextPlayerKept(afterAWarmOf: 0.4, third: 404) == true)
    }

    private func singleSlotPool() -> VideoPlayerPool {
        let loader = MediaServices.current.videoLoader
        let pool = VideoPlayerPool(maxPlayers: 1, ceiling: 1, makeItem: { mediaVideoItem(for: $0, loader: loader) })
        MediaServices.override(videoPool: pool)
        return pool
    }

    // Guards `onLost: { stopDriver(); if !gone { onSkipped() } }` in `StoryThumbnailVideo`: a tile
    // whose borrow the pool refuses (at the ceiling, Stage 2) skips its turn once; it
    // is not a failure, so the card is not removed for the session.
    @Test("a rail tile the pool refuses skips its turn and does not fail")
    func railTileRefusalIsASkip() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = singleSlotPool()
        let blocking = MediaOrigin.url("rail-blocker.mp4")
        let video = MediaOrigin.url("rail-refused.mp4")
        for url in [blocking, video] { MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: url) }
        let blocker = try #require(pool.borrow(key: "page", url: blocking, priority: .onScreen))
        let skipped = CallCount(), failed = CallCount()

        let window = MediaStage.mount(StoryThumbnail(
            item: StoryItemConfig(type: .video, url: video.absoluteString, duration: nil),
            poolKey: "tile", playing: true, repeatWindow: false, restartGeneration: 0,
            onWindowCompleted: {}, onFailed: { failed.value += 1 }, onSkipped: { skipped.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { skipped.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(skipped.value == 1)
        #expect(failed.value == 0)
        #expect(pool.heldKeys == ["page"], "nothing borrowed for the tile")
        pool.giveBack(key: "page", player: blocker, priority: .onScreen)
    }

    // Guards `onSkipped: { playback = playback.skip(index: index) }` in `StoryRail.card`: when the
    // pool takes a playing card's player back, the turn passes to the next card (here taking the
    // slot the other holder frees at once), instead of staying with the card that lost its player.
    @Test("a rail card whose player is evicted passes its turn to the next card")
    func evictedRailCardPassesTheTurn() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = singleSlotPool()
        let videos = [MediaOrigin.url("rail-turn-0.mp4"), MediaOrigin.url("rail-turn-1.mp4")]
        let other = MediaOrigin.url("rail-turn-other.mp4")
        for url in videos + [other] { MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: url) }
        let items = videos.map { StoryItemConfig(type: .video, url: $0.absoluteString, duration: nil) }
        let keys = (0 ..< 2).map { storyPoolKey(namespace: MediaStage.campaign, index: $0) }

        let window = MediaStage.mount(StoryRail(
            items: items, cardWidth: 100, cardHeight: 100, cardCornerRadius: 0,
            cardSpacing: 8, overlayOpen: false, onOpen: { _, _ in }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { pool.heldPlayer(for: keys[0]) != nil }, "card 0 has the first turn")

        let taker = try #require(pool.borrow(key: "page", url: other, priority: .viewerPage))
        pool.giveBack(key: "page", player: taker, priority: .viewerPage)

        #expect(await waitUntilMedia { pool.heldPlayer(for: keys[1]) != nil }, "card 1 took the turn")
        #expect(pool.heldPlayer(for: keys[0]) == nil)
    }

    // Guards the `mediaVideoBackdrop` branch of `playback.firstFrameShown ? groundAfterFirstFrame :
    // mediaVideoBackdrop` in `MediaVideo.body` as a handed-over player reaches it (V8-04; Android
    // X8-05): the viewer page over a player the rail card already holds shows the dark backdrop
    // while no first frame has been reported. The held origin never delivers one, so the
    // after-first-frame ground of a handed-over player is not covered here.
    @Test("a handed-over player's page shows the backdrop, not black, before any first frame")
    func handoverShowsTheBackdropBeforeAnyFirstFrame() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("handover.mp4")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)
        let pool = MediaServices.current.videoPool
        let item = StoryItemConfig(type: .video, url: video.absoluteString, duration: nil)
        let key = storyPoolKey(namespace: MediaStage.campaign, index: 0)
        let url = try #require(URL(string: item.url))
        let tile = try #require(pool.borrow(key: key, url: url, priority: .onScreen))
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

    // Guards `guard bytes > 0, elapsed >= Self.minimumElapsed` (the elapsed half) in
    // `SlowNetworkThroughput.note`: once the network reads slow, the plan warms story 1's first
    // bytes, which are already on disk. That warm answers at once and measures nothing; counted, it
    // would read as a link of Gbps and clear the slow verdict, and the next player would come back.
    @Test("a warm served from the cache does not clear a slow verdict")
    func cachedWarmDoesNotClearASlowVerdict() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = MediaServices.current.videoPool
        let (items, urls) = try serve([.video, .video, .video], holding: [2])
        await MediaPrefetch.warm(urls[1].absoluteString, kind: .video, bytes: storyFirstBytes)

        let window = openViewer(items, at: 0, slow: PathSlowNetworkSource())
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { pool.priority(of: poolKey(1)) == .viewerNext })
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: urls[2]).isEmpty })
        _ = await waitUntilMedia(timeout: 2.6) { false }
        MediaOrigin.release(urls[2])
        #expect(await waitUntilMedia(timeout: 2) { pool.priority(of: poolKey(1)) == nil }, "the slow warm turned it slow")
        ComponentTestHost.drainRunLoop(for: 1.0)

        #expect(pool.priority(of: poolKey(1)) == nil, "still slow after the cached warm")
    }

    // MARK: The rail's take-turns schedule, seen through the cards' players

    private func windowOf(_ ms: Int64, _ url: URL) -> StoryItemConfig {
        var item = StoryItemConfig(type: .video, url: url.absoluteString, duration: nil)
        item.thumbnailPlayback = StoryThumbnailPlaybackConfig(startTimeMs: 0, durationMode: .fixed, durationMs: ms)
        return item
    }

    private func serveVideos(_ count: Int) throws -> [URL] {
        try (0 ..< count).map { index in
            let url = MediaOrigin.url("rail-\(index).mp4")
            MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: url)
            return url
        }
    }

    private func mountRail(_ items: [StoryItemConfig], cardWidth: CGFloat = 40) -> UIWindow {
        MediaStage.mount(StoryRail(
            items: items, cardWidth: cardWidth, cardHeight: 100, cardCornerRadius: 0,
            cardSpacing: 8, overlayOpen: false, onOpen: { _, _ in }))
    }

    /// The app leaves the foreground and comes back: the rail restarts from its first card.
    private func backgroundAndReturn() {
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        ComponentTestHost.drainRunLoop(for: 0.1)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // Guards `updated.activeIndex = nextStoryRailIndex(eligible: playable, afterIndex: index)` in
    // `StoryRailState.complete`: the cards take turns in order, an image card has none, and after
    // the last video card the first one plays again.
    @Test("the cards on screen take turns, an image card has none, and the rotation wraps")
    func railCardsTakeTurns() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = MediaServices.current.videoPool
        let urls = try serveVideos(4)
        let image = MediaOrigin.url("rail-image.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: image)
        let items = [
            windowOf(400, urls[0]), StoryItemConfig(type: .image, url: image.absoluteString, duration: nil),
            windowOf(400, urls[2]), windowOf(400, urls[3]),
        ]

        let window = mountRail(items)
        defer { ComponentTestHost.unmount(window) }
        var turns: [Int] = [], before: Set<Int> = []
        _ = await waitUntilMedia(timeout: 20) {
            let now = Set((0 ..< 4).filter { pool.heldPlayer(for: poolKey($0)) != nil })
            turns += now.subtracting(before).sorted()
            before = now
            return turns.count >= 4
        }

        #expect(Array(turns.prefix(4)) == [0, 2, 3, 0])
    }

    // Guards `eligible: playable` (not `turnCandidates`) in `StoryRailState.complete`: a card the
    // pool took the player of keeps its place, so once the card that took its turn has played its
    // window the turn comes back to it.
    @Test("a rail card whose player was evicted gets its turn again after the next card's")
    func evictedRailCardStaysInTheRotation() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = singleSlotPool()
        let urls = try serveVideos(3)
        let keys = (0 ..< 2).map { poolKey($0) }

        let window = mountRail([windowOf(400, urls[0]), windowOf(400, urls[1])])
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { pool.heldPlayer(for: keys[0]) != nil }, "card 0 has the first turn")
        let taker = try #require(pool.borrow(key: "page", url: urls[2], priority: .viewerPage))
        pool.giveBack(key: "page", player: taker, priority: .viewerPage)
        #expect(await waitUntilMedia { pool.heldPlayer(for: keys[1]) != nil }, "card 1 took the turn")

        #expect(await waitUntilMedia(timeout: 10) { pool.heldPlayer(for: keys[0]) != nil }, "the turn came back to card 0")
    }

    // Guards `eligible.subtracting(failed)` in `StoryRailState.playable`: a card whose video
    // really failed is out of the rotation for the session, a restart does not bring it back, and
    // the one card left loops its window in place (`repeatWindow: playable.count == 1`).
    @Test("a rail card whose video failed is never tried again, and the card left loops in place")
    func failedRailCardLeavesTheRotation() async throws {
        install()
        defer { MediaOrigin.end() }
        let pool = MediaServices.current.videoPool
        let urls = try serveVideos(2)
        MediaOrigin.set(.status(404, Data("gone".utf8)), for: urls[0])
        let key = poolKey(1)

        let window = mountRail([windowOf(400, urls[0]), windowOf(400, urls[1])])
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { pool.heldPlayer(for: key) != nil }, "card 1 plays once card 0 failed")
        let player = try #require(pool.heldPlayer(for: key))
        let failedRequests = MediaOrigin.requests(for: urls[0]).count

        // Its 400 ms window ends, and it plays again from the top: the playhead jumps back.
        var peak = 0.0, jumpedBack = false
        _ = await waitUntilMedia(timeout: 6) {
            let now = player.currentTime().seconds
            if now < peak - 0.2 { jumpedBack = true }
            peak = max(peak, now)
            return jumpedBack
        }
        #expect(jumpedBack, "the lone card loops its window in place")
        backgroundAndReturn()
        ComponentTestHost.drainRunLoop(for: 1.5)

        #expect(MediaOrigin.requests(for: urls[0]).count == failedRequests, "the failed card is not tried again")
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
