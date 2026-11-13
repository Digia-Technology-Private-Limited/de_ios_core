import AVFoundation
import SwiftUI
import Testing
@testable import DigiaEngage
@testable import DigiaVideoEngine

/// The app page for the wait-queue suite: optional side cards above the main card, and the story
/// viewer opened over them when the test says so.
@MainActor
private final class CanvasVideoWaitPage: ObservableObject {
    @Published var sideShown = true
    @Published var stories: [StoryItemConfig]? = nil
}

private struct CanvasVideoWaitScreen: View {
    @ObservedObject var page: CanvasVideoWaitPage
    let sideSlot: String?
    var topSlot: String? = nil

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let topSlot { DigiaSlot(topSlot) { EmptyView() } }
                if let sideSlot, page.sideShown { DigiaSlot(sideSlot) { EmptyView() } }
                DigiaSlot("home_banner") { EmptyView() }
                Spacer(minLength: 0)
            }
            if let stories = page.stories {
                StoryViewer(entry: StoryViewerEntry(
                    stories: stories, startIndex: 0, restartOnCompleted: false, startMuted: true,
                    defaultDurationMs: 60_000, reporter: SilentStoryReporter(), onDismiss: {}
                )) { _ in EmptyView() }
                .environment(\.digiaCampaignKey, "wait_stories")
            }
        }
    }
}

@MainActor
private final class SilentStoryReporter: StoryViewerReporter {
    func onCompleted(total: Int, timeToCompleteMs: Int64) {}
    func onDismissed(index: Int) {}
}

extension RenderedUITests {
/// A canvas card authored with more videos than the live-player ceiling (the pool's wait queue,
/// OD-24 as amended 2026-11-12), driven from the shared fixture `canvas/canvas_video_player` with its
/// one video widget copied past the ceiling. Videos that cannot get a player show their still and
/// wait; they start when a player frees, longest waiting first; a video that wants to play waits
/// like any other, as nobody gives way inside Stage 2; and a video the story viewer took a player from plays again when the viewer
/// closes. Real `AVPlayer`s over the media suites' fake origin, on a pool with ceiling 3.
@Suite(
    "Canvas videos past the ceiling wait",
    .serialized,
    .tags(.integration, .behaviour, .inline, .media),
    .enabled(if: testkitAvailable, testkitSkipReason)
)
@MainActor
struct CanvasVideoWaitBehaviourTests {
    private static let ceiling = 3

    /// The canvas fixture with its video widget copied `count` times (`v0`, `v1`, …), each with its
    /// own URL on the fake origin; `autoplay` decides each copy's autoplay.
    private func canvas(
        _ count: Int, campaignKey: String = "test_canvas_video_player", slotKey: String = "home_banner",
        autoplay: (Int) -> Bool = { _ in true }
    ) throws -> [String: Any] {
        var campaign = try fixture("canvas/canvas_video_player")
        campaign["campaignKey"] = campaignKey
        campaign["id"] = "mock-\(campaignKey)"
        var template = try #require(campaign["templateConfig"] as? [String: Any])
        template["slotKey"] = slotKey
        var canvas = try #require(template["canvas"] as? [String: Any])
        var children = try #require(canvas["children"] as? [[String: Any]])
        let original = children.removeFirst()
        let movie = try testkitAsset("movie.mp4")
        let copies = try (0 ..< count).map { index -> [String: Any] in
            var copy = original
            copy["id"] = "v\(index)"
            copy["rect"] = ["x": 0.0, "y": Double(index) / Double(count), "width": 1.0, "height": 1.0 / Double(count)]
            var widget = try #require(copy["widget"] as? [String: Any])
            var props = try #require(widget["props"] as? [String: Any])
            let url = MediaOrigin.url("\(campaignKey)-\(index).mp4")
            MediaOrigin.set(.status(200, movie), for: url)
            props["source"] = ["url": url.absoluteString]
            props["autoplay"] = autoplay(index)
            props["showControls"] = false
            widget["props"] = props
            copy["widget"] = widget
            return copy
        }
        canvas["children"] = copies + children
        template["canvas"] = canvas
        campaign["templateConfig"] = template
        return campaign
    }

    private func key(_ index: Int, of campaignKey: String = "test_canvas_video_player") -> String {
        "canvas-video-\(campaignKey)-v\(index)"
    }

    /// A pool with ceiling 3 reading through the fake origin, for every video the SDK draws.
    private func install() -> VideoPlayerPool {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        let loader = MediaServices.current.videoLoader
        let pool = VideoPlayerPool(
            maxPlayers: Self.ceiling, ceiling: Self.ceiling,
            makeItem: { mediaVideoItem(for: $0, loader: loader) },
            releaseItem: { loader.cancelLoading(for: $0) })
        MediaServices.override(videoPool: pool)
        return pool
    }

    private func playing(_ pool: VideoPlayerPool, _ key: String) -> Bool {
        (pool.heldPlayer(for: key)?.avPlayer.rate ?? 0) > 0
    }

    private func start(
        _ campaigns: [[String: Any]], page: CanvasVideoWaitPage, sideSlot: String? = nil, topSlot: String? = nil
    ) async throws -> SdkHarness {
        let sdk = try await SdkHarness.start(campaigns: campaigns)
        try sdk.mount { CanvasVideoWaitScreen(page: page, sideSlot: sideSlot, topSlot: topSlot) }
        return sdk
    }

    // Fails if a refused video gives up instead of waiting: `waitOrGiveUp()` after the retry in
    // `MediaVideoPlayback.attemptBorrow`. Fails if a freed slot wakes nobody: `wakeWaiters()` in
    // `VideoPlayerPool.giveBack`.
    @Test("videos past the ceiling show their still, and the longest waiting starts when a playing one goes")
    func videosPastTheCeilingWaitInOrder() async throws {
        let pool = install()
        defer { MediaOrigin.end() }
        let side = try canvas(1, campaignKey: "side_canvas_video", slotKey: "side_banner")
        let main = try canvas(4)
        let page = CanvasVideoWaitPage()
        let sdk = try await start([side, main], page: page, sideSlot: "side_banner")
        defer { sdk.tearDown() }

        try sdk.deliver(keyOf(side))
        try await sdk.waitUntil("the side video plays", timeout: 5) { playing(pool, key(0, of: "side_canvas_video")) }
        try sdk.deliver(keyOf(main))
        try await sdk.waitUntil("two waiters", timeout: 5) { pool.queuedKeys.count == 2 }

        // SwiftUI mounts the card's videos in its own order; the queue keeps that order.
        let waiting = pool.queuedKeys
        let held = (0 ..< 4).map { key($0) }.filter { !waiting.contains($0) }
        #expect(held.count == 2 && held.allSatisfy { playing(pool, $0) }, "two of the card's videos play")
        #expect(pool.heldKeys.count == Self.ceiling)
        #expect(waiting.allSatisfy { pool.heldPlayer(for: $0) == nil }, "a waiting video shows its still")

        page.sideShown = false

        try await sdk.waitUntil("the longest-waiting video starts", timeout: 5) { playing(pool, waiting[0]) }
        #expect(pool.queuedKeys == [waiting[1]], "the other keeps waiting")
        #expect(pool.heldKeys.count == Self.ceiling)
    }

    // Fails if a Stage-2 borrow at the ceiling takes a paused holder's player again (decision 2,
    // R1-15): the refusal in `VideoPlayerPool.borrow`. Fails if the waiting video is not woken when
    // a paused one leaves: `wakeWaiters()` in `VideoPlayerPool.giveBack`.
    @Test("a video that plays on its own waits behind paused holders, and starts when one leaves")
    func autoplayWaitsForAPausedPlayer() async throws {
        let pool = install()
        defer { MediaOrigin.end() }
        // Three paused videos fill the ceiling; then a card whose video plays on its own appears.
        let main = try canvas(2) { _ in false }
        let side = try canvas(1, campaignKey: "side_canvas_video", slotKey: "side_banner") { _ in false }
        let top = try canvas(1, campaignKey: "top_canvas_video", slotKey: "top_banner")
        let page = CanvasVideoWaitPage()
        let sdk = try await start([main, side, top], page: page, sideSlot: "side_banner", topSlot: "top_banner")
        defer { sdk.tearDown() }
        try sdk.deliver(keyOf(main))
        try sdk.deliver(keyOf(side))
        try await sdk.waitUntil("the paused videos hold the ceiling", timeout: 5) { pool.heldKeys.count == Self.ceiling }
        let paused = pool.heldKeys
        let autoplay = key(0, of: "top_canvas_video")

        try sdk.deliver(keyOf(top))

        try await sdk.waitUntil("the autoplaying video waits", timeout: 5) { pool.queuedKeys == [autoplay] }
        #expect(pool.heldPlayer(for: autoplay) == nil, "it shows its still")
        #expect(pool.heldKeys == paused, "the paused videos keep their players")

        page.sideShown = false

        try await sdk.waitUntil("the autoplaying video plays", timeout: 5) { playing(pool, autoplay) }
        #expect(pool.queuedKeys.isEmpty)
    }

    // Fails if an evicted video gives up instead of waiting: `waitOrGiveUp()` in
    // `MediaVideoPlayback.evicted`. Fails if Stage 1 giving back wakes nobody: `wakeWaiters()` in
    // `VideoPlayerPool.giveBack`.
    @Test("a video the story viewer took a player from plays again when the viewer closes")
    func viewerEvictedVideoPlaysAgain() async throws {
        let pool = install()
        defer { MediaOrigin.end() }
        let main = try canvas(3)
        let page = CanvasVideoWaitPage()
        let sdk = try await start([main], page: page)
        defer { sdk.tearDown() }
        try sdk.deliver(keyOf(main))
        try await sdk.waitUntil("the card's videos play", timeout: 5) { (0 ..< 3).allSatisfy { playing(pool, key($0)) } }
        let story = MediaOrigin.url("wait-story.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: story)

        page.stories = [StoryItemConfig(type: .video, url: story.absoluteString, duration: nil)]

        let storyKey = storyPoolKey(namespace: "wait_stories", index: 0)
        try await sdk.waitUntil("the viewer's page holds a player", timeout: 5) { pool.priority(of: storyKey) == .viewerPage }
        try await sdk.waitUntil("a canvas video waits", timeout: 5) { !pool.queuedKeys.isEmpty }
        let evicted = try #require(pool.queuedKeys.first)
        #expect(evicted.hasPrefix("canvas-video-"))
        #expect(pool.heldPlayer(for: evicted) == nil, "the evicted video shows its still")

        page.stories = nil

        try await sdk.waitUntil("the evicted video plays again", timeout: 5) { playing(pool, evicted) }
        #expect(pool.queuedKeys.isEmpty)
    }
}
}
