import AVFoundation
import SwiftUI
import Testing
@testable import DigiaEngage
@testable import DigiaVideoEngine

/// The app page for the surface-lifecycle suite: optional side cards above the main card.
@MainActor
private final class CanvasVideoWaitPage: ObservableObject {
    @Published var sideShown = true
    @Published var topShown = true
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
        }
    }
}

extension RenderedUITests {
/// Canvas cards with videos, driven from the shared fixture `canvas/canvas_video_player` with its one
/// video widget copied, through the campaign: a card that replaces another in the same turn, and a
/// card that closes, get and give back their players. The pool's rules (no live-player ceiling,
/// decoder-busy replacement) are the engine's. Real `AVPlayer`s over the media suites' fake origin,
/// on a pool of 3.
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
