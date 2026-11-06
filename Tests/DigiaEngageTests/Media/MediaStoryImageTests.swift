import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// A story picture (`StoryRemoteImage`: the inline story's preview card, rail card and viewer page,
// and the canvas story's) draws through `MediaImage`. When it fails it reports once for the
// surface's campaign, and shows the flat dark box the story always showed, not the wrapper's
// "Image failed" placeholder.

extension RenderedUITests {
@MainActor
@Suite("Story image through MediaImage", .serialized, .tags(.media, .component, .inline))
struct MediaStoryImageTests {
    @Test("a story picture that fails reports once, for its campaign, and shows the story's dark box")
    func failedStoryPictureKeepsTheStoryLook() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("gone-story.png")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let recorder = HealthRecorder()

        let window = MediaStage.mount(StoryRemoteImage(urlString: target.absoluteString, fit: .fill))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(
            recorder.all == [
                HealthRecorder.Record(campaignKey: MediaStage.campaign, kind: .image, cause: "http_4xx")
            ])
        #expect(MediaOrigin.requests(for: target).count == 1)
        #expect(!MediaStage.shows("Image failed", in: window))

        // The middle of the 240x120 box, which is centred on the 390x844 frame, is the story's
        // #1A1A1A, not the wrapper's #F1F1F5 placeholder or the striped host behind the box.
        let drawn = ComponentTestHost.settledImage(of: window)
        let dark = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        for (x, y) in [(195, 422), (85, 372), (305, 472)] {
            let color = pixelColor(of: drawn, atX: x, y: y)
            #expect(color.map { colorsNearly($0, dark, tolerance: 0.02) } == true, "pixel \(x),\(y)")
        }
    }
}
}
