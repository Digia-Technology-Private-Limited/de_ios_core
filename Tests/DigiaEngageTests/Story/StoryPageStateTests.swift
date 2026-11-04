import AVFoundation
import CoreVideo
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The viewer page's state path (R2-STORY): `VideoStoryPage` reports ready/progress/end and
// failure through its owned `MediaVideoState` — no raw `AVPlayer` handout drives it anymore.
// Mounted with the real pool and a fake factory: the old `MediaVideo(spec:player:…)` call
// shape is gone from this file, so these prove the `MediaVideo(state:)` wiring end to end.
// Break-once: the `MediaVideo(state: video)` line in `VideoStoryPage.body` (reverting to the
// adapter, or dropping the state, leaves ready/progress/end silent).

private func pageStatePool(_ factory: PageStateFakeFactory) -> VideoPlayerPool {
    VideoPlayerPool(factory: factory, maxPlayers: 2)
}

private final class PageStateFakeFactory: PlayerFactory {
    var creates = 0
    func makePlayer() -> AVQueuePlayer {
        creates += 1
        return AVQueuePlayer()
    }
}

private func pageStateServices(_ pool: VideoPlayerPool) -> MediaServices {
    var services = MediaServices.unconfigured
    services.pool = { pool }
    return services
}

/// Synthesizes a tiny valid H.264 mp4 (one black 64x64 frame, 1 s), like the media suite's
/// helper: real AVFoundation parsing with no network and no checked-in binary fixture.
private func makePageStateMP4() async throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("digia-story-page-\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64,
        AVVideoHeightKey: 64,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
    let buffer = try #require(status == kCVReturnSuccess && pixelBuffer != nil ? pixelBuffer : nil)
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(
        CVPixelBufferGetBaseAddress(buffer),
        0,
        CVPixelBufferGetBytesPerRow(buffer) * 64)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    while !input.isReadyForMoreMediaData {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    adaptor.append(buffer, withPresentationTime: .zero)
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writer.finishWriting {
            if let error = writer.error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
    return url
}

@Suite("VideoStoryPage state path", .tags(.media, .component), .serialized)
@MainActor
struct StoryPageStateTests {
    // Fails if the page no longer reports through its state: without the state borrow the
    // ready handout never fires, progress never advances and the end never lands.
    @Test("a video page reports ready progress and end through its state", .tags(.slow))
    func videoPageReportsThroughItsState() async throws {
        let file = try await makePageStateMP4()
        defer { try? FileManager.default.removeItem(at: file) }
        let factory = PageStateFakeFactory()
        let pool = pageStatePool(factory)
        let services = pageStateServices(pool)
        let item = StoryItemConfig(type: .video, url: file.absoluteString, duration: 1_000)

        var readyPlayer: AVPlayer?
        var progresses: [Double] = []
        var ended = false
        var failed = false
        let window = mountMedia(
            VideoStoryPage(
                item: item,
                pageKey: "test/page-0",
                muted: true,
                playing: true,
                onReady: { readyPlayer = $0 },
                onProgress: { progresses.append($0) },
                onEnded: { ended = true },
                onBuffering: { _ in },
                onFailed: { failed = true }
            )
            .environment(\.digiaCampaignKey, "test-campaign")
            .environment(\.mediaServices, services)
        )
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia(timeout: 10) { readyPlayer != nil })
        #expect(await waitUntilMedia(timeout: 10) { (progresses.last ?? 0) > 0 })
        #expect(await waitUntilMedia(timeout: 15) { ended })
        #expect(!failed)
        #expect(pool.heldKeys() == ["test/page-0"])
    }

    // Fails if the page's give-up path is lost with the adapter: without the state's
    // `onGiveUp` wiring a missing file stalls instead of moving the viewer on.
    @Test("a missing file reports failure through the state")
    func missingFileReportsFailureThroughState() async {
        let factory = PageStateFakeFactory()
        let pool = pageStatePool(factory)
        let services = pageStateServices(pool)
        let item = StoryItemConfig(
            type: .video,
            url: "file:///tmp/story-page-test/missing-\(UUID().uuidString).mp4",
            duration: 5_000)

        var failed = false
        var ended = false
        let window = mountMedia(
            VideoStoryPage(
                item: item,
                pageKey: "test/page-1",
                muted: true,
                playing: true,
                onReady: { _ in },
                onProgress: { _ in },
                onEnded: { ended = true },
                onBuffering: { _ in },
                onFailed: { failed = true }
            )
            .environment(\.digiaCampaignKey, "test-campaign")
            .environment(\.mediaServices, services)
        )
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia(timeout: 10) { failed })
        #expect(!ended)
    }
}
