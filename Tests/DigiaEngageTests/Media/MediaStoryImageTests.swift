import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// A story picture (`StoryRemoteImage`: the inline story's preview card, rail card and viewer page,
// and the canvas story's) draws through `MediaImage`. When it fails it reports once for the
// surface's campaign. Only a rail card (which passes `storyRailFailureGround`) fills the failed
// box with #1A1A1A; every other surface shows the normal contract, its still or nothing.

extension RenderedUITests {
@MainActor
@Suite("Story image through MediaImage", .serialized, .tags(.media, .component, .inline))
struct MediaStoryImageTests {
    private static let dark = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)

    /// Mounts a story picture that 404s, waits for its one health report and returns the stage.
    private func failedStage(ground: Color?) async -> (UIWindow, HealthRecorder) {
        let target = MediaOrigin.url("gone-story.png")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()
        let window = MediaStage.mount(
            StoryRemoteImage(urlString: target.absoluteString, fit: .fill, ground: ground))
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(
            recorder.all == [
                HealthRecorder.Record(campaignKey: MediaStage.campaign, kind: .image, cause: "http_4xx")
            ])
        #expect(MediaOrigin.requests(for: target).count == 1)
        return (window, recorder)
    }

    @Test("a failed rail card picture reports once and is the #1A1A1A fill")
    func failedRailCardIsDark() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let (window, _) = await failedStage(ground: storyRailFailureGround)
        defer { ComponentTestHost.unmount(window) }

        // The middle of the 240x120 box is centred on the 390x844 frame.
        let drawn = ComponentTestHost.settledImage(of: window)
        for (x, y) in [(195, 422), (85, 372), (305, 472)] {
            let color = pixelColor(of: drawn, atX: x, y: y)
            #expect(color.map { colorsNearly($0, Self.dark, tolerance: 0.02) } == true, "pixel \(x),\(y)")
        }
    }

    @Test("a failed preview or viewer picture reports once and draws nothing of its own")
    func failedPreviewIsEmpty() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let (window, _) = await failedStage(ground: nil)
        defer { ComponentTestHost.unmount(window) }

        let drawn = ComponentTestHost.settledImage(of: window)
        for (x, y) in [(195, 422), (85, 372), (305, 472)] {
            let color = pixelColor(of: drawn, atX: x, y: y)
            #expect(color.map { colorsNearly($0, Self.dark, tolerance: 0.02) } == false, "pixel \(x),\(y)")
        }
    }
}
}
