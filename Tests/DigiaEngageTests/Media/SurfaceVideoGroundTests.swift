import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// OD-18 and OD-20: each video surface sets what shows around its video to what `main` drew there.
// The default is black (see `LegacyVideoGroundTests`); these are the surfaces that differ: the
// inline story's video page (#1A1A1A), a rail tile (its own still around the video), and the PIP
// window (nothing of ours, so the window shows through before the first frame).

extension RenderedUITests {
@MainActor
@Suite("Video ground per surface", .serialized, .tags(.media, .component))
struct SurfaceVideoGroundTests {
    private static let backdrop = UIColor(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255, alpha: 1)

    private func install() {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
    }

    /// The colour of a pixel `x` pt in from the stage's left edge, `y` pt down from its top.
    private func stagePixel(_ window: UIWindow, x: CGFloat, y: CGFloat) throws -> UIColor {
        let image = ComponentTestHost.settledImage(of: window)
        let left = (image.size.width - MediaStage.size.width) / 2
        let top = (image.size.height - MediaStage.size.height) / 2
        return try #require(pixelColor(of: image, atX: Int((left + x) * image.scale), y: Int((top + y) * image.scale)))
    }

    /// Waits until every player layer in the window has a frame, then lets `MediaVideo` note it.
    private func waitForFirstFrame(_ window: UIWindow) async throws {
        #expect(await waitUntilMedia {
            let layers = Self.playerLayers(in: window)
            return !layers.isEmpty && layers.allSatisfy { $0.isReadyForDisplay }
        })
        try await Task.sleep(nanoseconds: 200_000_000)
        ComponentTestHost.drainRunLoop(for: 0.2)
    }

    private static func playerLayers(in view: UIView) -> [AVPlayerLayer] {
        // A video view draws through the engine player's layer, a sublayer of its own.
        let own = [view.layer] + (view.layer.sublayers ?? [])
        return own.compactMap { $0 as? AVPlayerLayer } + view.subviews.flatMap { playerLayers(in: $0) }
    }

    // Fails if `videoGroundAfterFirstFrame: mediaVideoBackdrop` is dropped from the inline story's
    // `StoryViewerEntry` in `DigiaInlineStoryView.swift` (the page then letterboxes on black), or
    // if the viewer, the page or the surface stops handing it to `MediaVideo`.
    @Test("the inline story's video page letterboxes on #1A1A1A after the first frame")
    func inlineStoryPageLetterboxIsTheDarkGrey() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("inline-page.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        var item = StoryItemConfig(type: .video, url: video.absoluteString, duration: nil)
        item.boxFit = .contain
        let state = InlineStoryOverlayState(
            config: InlineStoryConfig(slotKey: "slot", items: [item]), initialIndex: 0,
            payload: CEPTriggerPayload(cepCampaignId: "ground", campaignKey: MediaStage.campaign, cepMetadata: [:]))

        // movie.mp4 is 4:3, so in the 2:1 stage it pillarboxes: 40 pt each side.
        let window = MediaStage.mount(InlineStoryOverlayContent(state: state))
        defer { ComponentTestHost.unmount(window) }
        try await waitForFirstFrame(window)

        let pillar = try stagePixel(window, x: 10, y: MediaStage.size.height / 2)
        #expect(colorsNearly(pillar, Self.backdrop, tolerance: 0.03), "letterbox is \(pillar), not #1A1A1A")
    }

    // Fails if a rail tile stops passing `bare: true` and drawing its still beneath (in
    // `StoryVideoSurface`): the tile then letterboxes on `MediaVideo`'s black, hiding its still.
    @Test("a rail tile letterboxes on its own still after the first frame", arguments: [true, false])
    func railTileLetterboxIsItsStill(authoredColour: Bool) async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("rail-ground.mp4")
        MediaOrigin.set(.status(200, try testkitAsset("movie.mp4")), for: video)
        var item = StoryItemConfig(type: .video, url: video.absoluteString, duration: nil)
        item.thumbnail = authoredColour ? .color("#FF0000") : nil
        item.thumbnailBoxFit = .contain

        let window = MediaStage.mount(StoryRail(
            items: [item], cardWidth: MediaStage.size.width, cardHeight: MediaStage.size.height,
            cardCornerRadius: 0, cardSpacing: 0, overlayOpen: false, onOpen: { _, _ in }))
        defer { ComponentTestHost.unmount(window) }
        try await waitForFirstFrame(window)

        let pillar = try stagePixel(window, x: 10, y: MediaStage.size.height / 2)
        // An authored colour replaces the #1A1A1A tile ground.
        #expect(colorsNearly(pillar, authoredColour ? .red : Self.backdrop, tolerance: 0.03), "letterbox is \(pillar)")
    }

    // Fails if the PIP's `MediaVideo` in `floater_media_view.swift` loses `bare: true`: the window
    // then draws #1A1A1A (and, past 400 ms, a spinner) over its own background.
    @Test("the PIP window's own background shows until the video's first frame")
    func pipDrawsNoBackdropBeforeTheFirstFrame() async throws {
        install()
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("pip-ground.mp4")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)
        let media = FloaterMediaConfig(
            kind: .video, url: video.absoluteString, aspectRatio: 0, loop: true, autoplay: true, volume: 0.5,
            startMuted: true)

        let window = MediaStage.mount(ZStack {
            Color(uiColor: .red)
            FloaterMediaView(
                media: media, videoPlayerKey: "pip-ground-\(UUID().uuidString)", muted: true, cover: true,
                resolvedUrl: video.absoluteString, preloadedImage: nil)
        })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty })
        // Past the spinner delay: a spinner would draw white at the centre.
        _ = await waitUntilMedia(timeout: MediaVideo.defaultSpinnerDelay + 0.3) { false }

        let corner = try stagePixel(window, x: 6, y: 6)
        let centre = try stagePixel(window, x: MediaStage.size.width / 2, y: MediaStage.size.height / 2)
        #expect(colorsNearly(corner, .red, tolerance: 0.03), "the window shows through, got \(corner)")
        #expect(colorsNearly(centre, .red, tolerance: 0.03), "no spinner, got \(centre)")
        MediaOrigin.release(video)
    }
}
}
