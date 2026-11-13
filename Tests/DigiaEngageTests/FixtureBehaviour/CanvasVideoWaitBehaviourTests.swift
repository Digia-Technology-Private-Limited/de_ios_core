import AVFoundation
import SwiftUI
import Testing
@testable import DigiaEngage
@testable import DigiaVideoEngine

/// The app page for the capacity suite: optional side cards above the main card, and the story
/// viewer opened over them when the test says so.
@MainActor
private final class CanvasVideoWaitPage: ObservableObject {
    @Published var sideShown = true
    @Published var topShown = true
    @Published var stories: [StoryItemConfig]? = nil
}

private struct CanvasVideoWaitScreen: View {
    @ObservedObject var page: CanvasVideoWaitPage
    let sideSlot: String?
    var topSlot: String? = nil

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let topSlot, page.topShown { DigiaSlot(topSlot) { EmptyView() } }
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
/// A canvas card authored with more videos than the pool's size, driven from the shared fixture
/// `canvas/canvas_video_player` with its one video widget copied. There is no live-player ceiling
/// (decoder-driven capacity, 2026-11-13): every video gets a player, the story viewer takes none,
/// and capacity is met only when the OS says no decoder is free, then the busy video takes another's
/// player and that one shows its still. Real `AVPlayer`s over the media suites' fake origin, on a
/// pool of 3.
@Suite(
    "Canvas videos with no live-player ceiling",
    .serialized,
    .tags(.integration, .behaviour, .inline, .media),
    .enabled(if: testkitAvailable, testkitSkipReason)
)
@MainActor
struct CanvasVideoWaitBehaviourTests {
    private static let poolSize = 3

    /// The canvas fixture with its video widget copied `count` times (`v0`, `v1`, …), each with its
    /// own URL on the fake origin; `autoplay` decides each copy's autoplay.
    private func canvas(
        _ count: Int, campaignKey: String = "test_canvas_video_player", slotKey: String = "home_banner",
        held: Set<Int> = [], autoplay: (Int) -> Bool = { _ in true }
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
            MediaOrigin.set(.status(200, held.contains(index) ? Data() : movie), for: url, held: held.contains(index))
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

    /// A pool of 3 reading through the fake origin, for every video the SDK draws.
    private func install() -> VideoPlayerPool {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        let loader = MediaServices.current.videoLoader
        let pool = VideoPlayerPool(
            maxPlayers: Self.poolSize,
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

    // Fails if a ceiling comes back: a borrow past the pool's size that is refused or queued instead of
    // given a player (`VideoPlayerPool.borrow`).
    @Test("every video of a card plays, past the pool's size")
    func everyVideoPlaysPastThePoolSize() async throws {
        let pool = install()
        defer { MediaOrigin.end() }
        let side = try canvas(1, campaignKey: "side_canvas_video", slotKey: "side_banner")
        let main = try canvas(4)
        let page = CanvasVideoWaitPage()
        let sdk = try await start([side, main], page: page, sideSlot: "side_banner")
        defer { sdk.tearDown() }

        try sdk.deliver(keyOf(side))
        try sdk.deliver(keyOf(main))

        try await sdk.waitUntil("all five videos play", timeout: 5) {
            playing(pool, key(0, of: "side_canvas_video")) && (0 ..< 4).allSatisfy { playing(pool, key($0)) }
        }
        #expect(pool.heldKeys.count == 5, "five holders on a pool of \(Self.poolSize)")
        #expect(pool.queuedKeys.isEmpty)
    }

    // Fails if Stage 1 takes a player when nothing is busy (the old "take at the ceiling" rule):
    // a story page borrowing in `VideoPlayerPool.borrow`.
    @Test("the story viewer opening takes no player from the card's videos")
    func viewerTakesNothing() async throws {
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
        #expect((0 ..< 3).allSatisfy { playing(pool, key($0)) }, "the card's videos still play")
    }

    // Fails if a decoder-busy canvas video does not take a player, or the taken one retakes by itself:
    // `replaceForDecoderBusy` as `VideoShowing` calls it for a canvas `MediaVideo`.
    @Test("a decoder-busy canvas video takes another's player, which shows its still")
    func decoderBusyVideoTakesAnothersPlayer() async throws {
        let pool = install()
        defer { MediaOrigin.end() }
        let main = try canvas(3, held: [2])
        let page = CanvasVideoWaitPage()
        let sdk = try await start([main], page: page)
        defer { sdk.tearDown() }
        try sdk.deliver(keyOf(main))
        try await sdk.waitUntil("two play and the third holds an unready player", timeout: 5) {
            playing(pool, key(0)) && playing(pool, key(1)) && pool.heldPlayer(for: key(2)) != nil
        }
        let busy = try #require(pool.heldPlayer(for: key(2)))

        simulateDecoderBusy(busy)

        try await sdk.waitUntil("one of the playing videos was taken", timeout: 5) {
            [key(0), key(1)].filter { pool.heldPlayer(for: $0) == nil }.count == 1
        }
        #expect(pool.heldPlayer(for: key(2)) != nil, "the busy video holds a player")
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect([key(0), key(1)].filter { pool.heldPlayer(for: $0) == nil }.count == 1, "the taken one stays on its still")
        #expect(pool.heldKeys.count == 2)
    }

    // The restored surface rule, through the campaign: a card replacing another in the same turn
    // gets a player at once, with no retry and no waiting.
    @Test("a card replacing another in the same turn gets a player")
    func sameTurnReplacementGetsAPlayer() async throws {
        let pool = install()
        defer { MediaOrigin.end() }
        let main = try canvas(2)
        let top = try canvas(1, campaignKey: "top_canvas_video", slotKey: "top_banner")
        let side = try canvas(1, campaignKey: "side_canvas_video", slotKey: "side_banner")
        let page = CanvasVideoWaitPage()
        page.topShown = false
        let sdk = try await start([main, top, side], page: page, sideSlot: "side_banner", topSlot: "top_banner")
        defer { sdk.tearDown() }
        try sdk.deliver(keyOf(main))
        try sdk.deliver(keyOf(top))
        try sdk.deliver(keyOf(side))
        try await sdk.waitUntil("the side and card videos play", timeout: 5) {
            playing(pool, key(0, of: "side_canvas_video")) && playing(pool, key(0))
        }
        let replacing = key(0, of: "top_canvas_video")

        page.sideShown = false
        page.topShown = true

        try await sdk.waitUntil("the replacing video plays", timeout: 5) { playing(pool, replacing) }
        #expect(pool.heldPlayer(for: key(0, of: "side_canvas_video")) == nil, "the leaving card gave its player back")
    }

    // Fails if a card that goes away keeps its players: the give-back in `VideoShowing.close`.
    @Test("a card that closes gives its players back")
    func closedCardGivesItsPlayersBack() async throws {
        let pool = install()
        defer { MediaOrigin.end() }
        let side = try canvas(2, campaignKey: "side_canvas_video", slotKey: "side_banner")
        let page = CanvasVideoWaitPage()
        let sdk = try await start([side], page: page, sideSlot: "side_banner")
        defer { sdk.tearDown() }
        try sdk.deliver(keyOf(side))
        try await sdk.waitUntil("the videos hold players", timeout: 5) { pool.heldKeys.count == 2 }

        page.sideShown = false

        try await sdk.waitUntil("the players are given back", timeout: 5) { pool.heldKeys.isEmpty }
    }
}
}
