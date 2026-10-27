import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@Suite("Nudge surface configuration", .tags(.nudge, .contract))
struct NudgeSurfaceConfigTests {
    @Test("parses nudge barrier color alpha as alpha-first hex")
    func parsesBarrierColorAlphaFirstHex() throws {
        let surface = NudgeSurface.fromJson(["barrierColor": "#4D000000"])
        let color = try #require(surface.barrierColor)
        let resolved = UIColor(color)
        var alpha: CGFloat = 0

        #expect(resolved.getRed(nil, green: nil, blue: nil, alpha: &alpha))
        #expect(abs(alpha - 77.0 / 255.0) < 0.001)
    }

    @Test("parses autoDismissAfterMs from container config")
    func parsesAutoDismissAfterMs() {
        let surface = NudgeSurface.fromJson(["autoDismissAfterMs": 5000])
        #expect(surface.autoDismissAfterMs == 5000)
    }

    @Test("preserves nudge image fit and blurhash placeholder")
    func parsesImageFitAndPlaceholder() throws {
        let config = try #require(try NudgeConfig.fromJson([
            "layout": [
                "type": "digia/column",
                "children": [[
                    "type": "digia/image",
                    "props": [
                        "src": ["imageSrc": "https://cdn.example.com/hero.png"],
                        "fit": "contain",
                        "placeholder": [
                            "type": "blurhash",
                            "blurHash": "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
                        ],
                    ],
                ]],
            ],
        ]))
        guard case .image(let image) = config.layout.children.first else {
            Issue.record("Expected an image node")
            return
        }
        #expect(image.fit == .contain)
        #expect(image.placeholder?.blurHash == "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
    }
}
