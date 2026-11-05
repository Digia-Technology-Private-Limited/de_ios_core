import Foundation
import Lottie
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// The failure look of `MediaImage` and `MediaLottie` over the fake origin: the caller's
// `errorContent` replaces the default placeholder ("Image failed" / "Lottie failed") when a load
// fails or the URL is unusable, is never drawn over media that loaded, and the default placeholder
// fills the whole box. The caller's content is a line of text (`MediaStage.errorMarker`), found in
// the accessibility tree; the default placeholder is found by its own label.

extension RenderedUITests {
@MainActor
@Suite("Media error content", .serialized, .tags(.media, .component))
struct MediaErrorContentTests {
    /// An image whose URL a test can switch, with the caller's error content.
    private struct ImageHost: View {
        @ObservedObject var model: MediaModel
        var onSuccess: (() -> Void)?
        var onFailure: (() -> Void)?

        var body: some View {
            MediaImage(
                url: model.url, onSuccess: onSuccess, onFailure: onFailure, errorContent: MediaStage.errorContent)
        }
    }

    /// An animation whose URL a test can switch, with the caller's error content.
    private struct LottieHost: View {
        @ObservedObject var model: MediaModel

        var body: some View {
            MediaLottie(url: model.url, errorContent: MediaStage.errorContent)
        }
    }

    @Test("the caller's error content replaces the placeholder when a picture fails")
    func errorContentReplacesThePicturePlaceholder() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("gone.png")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)

        let window = MediaStage.image(url: target.absoluteString, errorContent: MediaStage.errorContent)
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { MediaStage.shows(MediaStage.errorMarker, in: window) })

        #expect(!MediaStage.shows("Image failed", in: window))
    }

    @Test(
        "the caller's error content replaces the placeholder for a blank or unresolved url",
        arguments: ["", "https://media-fake.origin.test/{{picture}}.png"])
    func errorContentReplacesThePlaceholderForAnUnusableURL(url: String) async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let failures = CallCount()

        let window = MediaStage.image(
            url: url, onFailure: { failures.value += 1 }, errorContent: MediaStage.errorContent)
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        #expect(await waitUntilMedia { MediaStage.shows(MediaStage.errorMarker, in: window) })

        #expect(!MediaStage.shows("Image failed", in: window))
    }

    @Test("the caller's error content replaces the placeholder when an animation fails")
    func errorContentReplacesTheAnimationPlaceholder() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("gone.json")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)

        let window = MediaStage.lottie(url: target.absoluteString, errorContent: MediaStage.errorContent)
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { MediaStage.shows(MediaStage.errorMarker, in: window) })

        #expect(!MediaStage.shows("Lottie failed", in: window))
    }

    @Test("the caller's error content is never drawn over a loaded picture")
    func errorContentIsNeverDrawnOverALoadedPicture() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let good = MediaOrigin.url("good.png")
        let gone = MediaOrigin.url("gone.png")
        let better = MediaOrigin.url("better.png")
        MediaOrigin.set(.status(200, MediaFixtures.quadrants), for: good)
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: gone)
        MediaOrigin.set(.status(200, MediaFixtures.quadrants), for: better)
        let successes = CallCount()
        let failures = CallCount()
        let model = MediaModel(url: good.absoluteString)

        let window = MediaStage.mount(
            ImageHost(model: model, onSuccess: { successes.value += 1 }, onFailure: { failures.value += 1 }))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { successes.value == 1 })
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(!MediaStage.shows(MediaStage.errorMarker, in: window))

        model.url = gone.absoluteString
        #expect(await waitUntilMedia { MediaStage.shows(MediaStage.errorMarker, in: window) })
        #expect(failures.value == 1)

        model.url = better.absoluteString
        #expect(await waitUntilMedia { successes.value == 2 })
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(!MediaStage.shows(MediaStage.errorMarker, in: window))
    }

    @Test("the caller's error content is never drawn over a loaded animation")
    func errorContentIsNeverDrawnOverALoadedAnimation() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let good = MediaOrigin.url("good.json")
        let gone = MediaOrigin.url("gone.json")
        let better = MediaOrigin.url("better.json")
        MediaOrigin.set(.status(200, MediaFixtures.marker), for: good)
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: gone)
        MediaOrigin.set(.status(200, MediaFixtures.marker), for: better)
        let model = MediaModel(url: good.absoluteString)

        let window = MediaStage.mount(LottieHost(model: model))
        defer { ComponentTestHost.unmount(window) }
        #expect(await MediaStage.animationView(in: window) != nil)
        #expect(!MediaStage.shows(MediaStage.errorMarker, in: window))

        model.url = gone.absoluteString
        #expect(await waitUntilMedia { MediaStage.shows(MediaStage.errorMarker, in: window) })

        model.url = better.absoluteString
        #expect(await MediaStage.animationView(in: window) != nil)
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(!MediaStage.shows(MediaStage.errorMarker, in: window))
    }

    /// The zoom and focal point of the picture a failure replaces: (zoom, focal x, focal y).
    nonisolated static let placements: [(CGFloat, CGFloat, CGFloat)] = [
        (0.5, 0.5, 0.5), (0.5, 0, 0), (2, 1, 1), (1, 0, 1),
    ]

    @Test(
        "a failed picture's placeholder fills the whole box whatever the zoom and focal point",
        arguments: placements)
    func placeholderFillsTheBox(zoom: CGFloat, focalX: CGFloat, focalY: CGFloat) async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("gone-\(zoom)-\(focalX)-\(focalY).png")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)
        let failures = CallCount()

        let window = MediaStage.image(
            url: target.absoluteString, focalX: focalX, focalY: focalY, zoom: zoom,
            onFailure: { failures.value += 1 })
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { failures.value > 0 })
        #expect(await waitUntilMedia { MediaStage.shows("Image failed", in: window) })
        ComponentTestHost.drainRunLoop(for: 0.3)

        // Near each corner and near the middle of the left and right edges of the 240x120 box,
        // which is centred on the 390x844 frame and so spans x 75...315, y 362...482. The label
        // sits in the middle, off these points; the host behind the box is striped.
        let drawn = ComponentTestHost.settledImage(of: window)
        let placeholder = UIColor(red: 0xF1 / 255, green: 0xF1 / 255, blue: 0xF5 / 255, alpha: 1)
        let points = [(85, 372), (305, 372), (85, 472), (305, 472), (78, 422), (312, 422)]
        for (x, y) in points {
            let color = pixelColor(of: drawn, atX: x, y: y)
            #expect(color.map { colorsNearly($0, placeholder, tolerance: 0.02) } == true, "pixel \(x),\(y)")
        }
    }
}
}
