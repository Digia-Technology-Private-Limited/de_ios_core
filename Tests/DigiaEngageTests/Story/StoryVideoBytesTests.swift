import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage
@testable import DigiaVideoEngine

// T5: a story video's bytes are downloaded once. `main` streamed the item from the network while
// `DigiaVideoFileCache` downloaded the whole file again for its cache (`StoryVideoPlayback`), and
// cut the poster with `StoryVideoPosterCache`; both are gone. A story page now reads through the
// range cache like every other video, so the request log shows one read serving both playback and
// the cache.

extension RenderedUITests {
@MainActor
@Suite("Story video bytes", .serialized, .tags(.inline, .media, .component))
struct StoryVideoBytesTests {
    private func page(_ item: StoryItemConfig, ready: CallCount) -> VideoStoryPage {
        VideoStoryPage(
            item: item, pageKey: "page-\(UUID().uuidString)", muted: true, playing: true, startMs: 0,
            onReady: { _ in ready.value += 1 }, onEnded: {}, onFailure: {}, onLost: {})
    }

    // Guards `loader.playerItem(for: url) ?? AVPlayerItem(url: url)` in `mediaVideoItem`: a remote
    // item that skips the range cache never reaches the cache's origin session, so the log is empty.
    @Test("a first view asks for no byte range twice, a second view on a new player and pool asks for none")
    func aFirstViewFetchesEachRangeOnce() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("story-bytes.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        let item = StoryItemConfig(type: .video, url: video.absoluteString, duration: nil)

        let ready = CallCount()
        let first = MediaStage.mount(page(item, ready: ready))
        #expect(await waitUntilMedia { ready.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)
        ComponentTestHost.unmount(first)

        let ranges = MediaOrigin.requests(for: video).map { $0.range ?? "whole" }
        #expect(!ranges.isEmpty, "the page read through the range cache")
        #expect(Set(ranges).count == ranges.count, "each range asked for once: \(ranges)")

        // A second view, on a player and a pool of its own, reads the same store.
        var services = MediaServices.current
        let loader = services.videoLoader
        services.videoPool = VideoPlayerPool(makeItem: { mediaVideoItem(for: $0, loader: loader) })
        let secondReady = CallCount()
        let second = MediaStage.mount(page(item, ready: secondReady).environment(\.mediaServices, services))
        defer { ComponentTestHost.unmount(second) }
        #expect(await waitUntilMedia { secondReady.value > 0 })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(MediaOrigin.requests(for: video).count == ranges.count, "nothing is fetched again")
    }
}
}
