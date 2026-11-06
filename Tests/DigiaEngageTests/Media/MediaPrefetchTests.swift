import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension RenderedUITests {
@MainActor
@Suite("MediaPrefetch", .serialized, .tags(.media, .component))
struct MediaPrefetchTests {
    private static let warmBytes = 64 * 1_024

    /// The first byte each request to `url` asked for, in log order. A request with no Range
    /// header asks from byte 0.
    private func rangeStarts(_ url: URL) -> [Int] {
        MediaOrigin.requests(for: url).map { request in
            request.range.flatMap { Int($0.dropFirst("bytes=".count).split(separator: "-").first ?? "") } ?? 0
        }
    }

    // Guards the `.video` branch of `MediaPrefetch.warm`, which fills the store the player reads.
    @Test("warm then play reuses the warmed bytes")
    func warmThenPlayReusesBytes() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("warm.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)

        await MediaPrefetch.warm(video.absoluteString, kind: .video, bytes: Self.warmBytes)
        #expect(MediaOrigin.requests(for: video).count == 1)

        let frames = CallCount()
        let window = MediaStage.mount(MediaVideo(url: video.absoluteString, onFirstFrame: { frames.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { frames.value > 0 })

        // The warm is the log's first request; nothing after it asks for a warmed byte again.
        let starts = rangeStarts(video)
        #expect(starts.first == 0)
        #expect(starts.dropFirst().allSatisfy { $0 >= Self.warmBytes })
    }

    @Test("warming an item already cached makes no request")
    func warmingCachedItemMakesNoRequest() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("rewarm.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)

        await MediaPrefetch.warm(video.absoluteString, kind: .video, bytes: Self.warmBytes)
        await MediaPrefetch.warm(video.absoluteString, kind: .video, bytes: Self.warmBytes)

        #expect(MediaOrigin.requests(for: video).count == 1)
    }

    // Guards `catch { return 0 }` in the `.video` branch of `MediaPrefetch.warm`: a failed warm
    // answers 0, so the throughput sample the story plan takes from it is never a fast one (V8-01).
    @Test("a warm the origin refuses answers 0 bytes")
    func failedWarmAnswersZero() async {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("warm-500.mp4")
        MediaOrigin.set(.status(500, Data("boom".utf8)), for: video)

        let delivered = await MediaPrefetch.warm(video.absoluteString, kind: .video, bytes: Self.warmBytes)

        #expect(delivered == 0)
    }

    // Guards `min(asked, Int(total))` in `MediaPrefetch.warm`: a clip shorter than the window
    // delivers all of it, not the window, so a short clip does not overstate throughput (V8-01).
    @Test("a clip shorter than the window answers its own length")
    func shortClipAnswersItsLength() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("warm-short.mp4")
        let clip = try testkitAsset("movie.mp4")
        MediaOrigin.set(.status(200, clip), for: video)

        let delivered = await MediaPrefetch.warm(video.absoluteString, kind: .video, bytes: clip.count + 4_096)

        #expect(delivered == clip.count)
    }
}
}
