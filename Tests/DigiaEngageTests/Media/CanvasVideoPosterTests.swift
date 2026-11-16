import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension RenderedUITests {
@MainActor
@Suite("Canvas video poster", .serialized, .tags(.media, .component))
struct CanvasVideoPosterTests {
    // Fails if the canvas `MediaVideo` call in `CanvasVideoRenderer` stops passing
    // `thumbnailUrl: poster?.url`: the video then shows the bare backdrop before its first frame.
    @Test("a canvas video's props.poster is its still until the first frame")
    func posterIsTheStill() async throws {
        MediaOrigin.install()
        MediaServices.override(videoSession: MediaOrigin.session())
        defer { MediaOrigin.end() }
        let video = MediaOrigin.url("canvas-held.mp4")
        let poster = MediaOrigin.url("tint-star-icon.png")
        MediaOrigin.set(.status(200, Data()), for: video, held: true)
        MediaOrigin.set(.status(200, try testkitAsset("tint-star-icon.png")), for: poster)

        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 240,
            "canvasHeight": 120,
            "background": ["type": "solid", "color": ["value": "#00000000"]],
            "children": [[
                "kind": "widget",
                "id": "video",
                "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
                "widget": [
                    "id": "v",
                    "type": "digia/videoPlayer",
                    "props": [
                        "source": ["url": video.absoluteString],
                        "fit": "contain",
                        "showControls": false,
                        "poster": [
                            "url": poster.absoluteString,
                            "placeholder": ["type": "blurhash", "blurHash": "LEHV6nWB2yk8pyo0adR*.7kCMdnj"],
                        ],
                    ],
                ],
            ]],
        ])
        let window = MediaStage.mount(InlineCampaignCanvasView(
            canvas: canvas, designWidth: 240, cornerRadius: 0, margin: InlineCanvasMargin(), onAction: { _ in }))
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { !MediaOrigin.requests(for: video).isEmpty })
        // The poster decodes after its request: the black star then covers the box's centre.
        #expect(await waitUntilMedia {
            let image = ComponentTestHost.settledImage(of: window)
            return pixelColor(
                of: image, atX: Int(image.size.width / 2 * image.scale), y: Int(image.size.height / 2 * image.scale)
            ).map { colorsNearly($0, .black) } ?? false
        })
        MediaOrigin.release(video)
    }
}
}
