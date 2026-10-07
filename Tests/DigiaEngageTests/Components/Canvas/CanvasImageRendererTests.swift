import Foundation
import SDWebImage
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas image renderer", .serialized, .tags(.canvas, .component, .media))
struct CanvasImageRendererTests {

    // MARK: - 1. Parser Options & Preservation

    @Test("image parser preserves every authored property")
    func parserPreservesAuthoredProperties() throws {
        let widget = try parsedImage([
            "source": [
                "url": "https://example.invalid/light.png",
                "darkUrl": "https://example.invalid/dark.png",
                "placeholder": [
                    "type": "blurhash",
                    "blurHash": "LEHLk~WB2yk8pyo0adR*.7kCMdnj",
                ],
            ],
            "fit": "contain",
            "positionX": 0.25,
            "positionY": 0.75,
            "scale": 2.5,
            "tintColor": "#FF0000FF",
        ])

        guard case .image(_, let source, let fit, let posX, let posY, let scale, let tint) = widget else {
            Issue.record("Expected a parsed image widget")
            return
        }

        #expect(source.url == "https://example.invalid/light.png")
        #expect(source.darkUrl == "https://example.invalid/dark.png")
        #expect(source.placeholder?.type == .blurhash)
        #expect(source.placeholder?.blurHash == "LEHLk~WB2yk8pyo0adR*.7kCMdnj")
        #expect(fit == "contain")
        #expect(posX == 0.25)
        #expect(posY == 0.75)
        #expect(scale == 2.5)
        #expect(tint?.lightHex == "#FF0000FF")
    }

    @Test("image parser clamps out-of-range focal coordinates and scale")
    func parserClampsOutOfRangeOptions() throws {
        let widget = try parsedImage([
            "positionX": -0.8,
            "positionY": 1.9,
            "scale": 9.5,
        ])

        guard case .image(_, _, _, let posX, let posY, let scale, _) = widget else {
            Issue.record("Expected a parsed image widget")
            return
        }

        #expect(posX == 0.0)
        #expect(posY == 1.0)
        #expect(scale == 4.0)

        let widgetMinScale = try parsedImage([
            "positionX": 1.5,
            "positionY": -0.2,
            "scale": 0.01,
        ])

        guard case .image(_, _, _, let minX, let minY, let minScale, _) = widgetMinScale else {
            Issue.record("Expected a parsed image widget")
            return
        }

        #expect(minX == 1.0)
        #expect(minY == 0.0)
        #expect(minScale == 0.1)
    }

    @Test("image parser applies default values when optional properties are omitted")
    func parserDefaults() throws {
        let widget = try parsedImage([:])

        guard case .image(_, let source, let fit, let posX, let posY, let scale, let tint) = widget else {
            Issue.record("Expected a parsed image widget")
            return
        }

        #expect(source.url.isEmpty)
        #expect(source.darkUrl == nil)
        #expect(source.placeholder == nil)
        #expect(fit == "cover")
        #expect(posX == 0.5)
        #expect(posY == 0.5)
        #expect(scale == 1.0)
        #expect(tint == nil)
    }

    // MARK: - 2. Focal Alignment Boundaries

    @Test("focalAlignment maps 9 quadrants correctly across 0.34 and 0.66 thresholds")
    func focalAlignmentQuadrants() {
        // Top row (y < 0.34)
        #expect(focalAlignment(x: 0.0, y: 0.0) == .topLeading)
        #expect(focalAlignment(x: 0.33, y: 0.33) == .topLeading)
        #expect(focalAlignment(x: 0.34, y: 0.1) == .top)
        #expect(focalAlignment(x: 0.5, y: 0.2) == .top)
        #expect(focalAlignment(x: 0.66, y: 0.1) == .top)
        #expect(focalAlignment(x: 0.67, y: 0.0) == .topTrailing)
        #expect(focalAlignment(x: 1.0, y: 0.33) == .topTrailing)

        // Center row (0.34 <= y <= 0.66)
        #expect(focalAlignment(x: 0.1, y: 0.34) == .leading)
        #expect(focalAlignment(x: 0.33, y: 0.5) == .leading)
        #expect(focalAlignment(x: 0.34, y: 0.34) == .center)
        #expect(focalAlignment(x: 0.5, y: 0.5) == .center)
        #expect(focalAlignment(x: 0.66, y: 0.66) == .center)
        #expect(focalAlignment(x: 0.67, y: 0.5) == .trailing)
        #expect(focalAlignment(x: 1.0, y: 0.66) == .trailing)

        // Bottom row (y > 0.66)
        #expect(focalAlignment(x: 0.0, y: 0.67) == .bottomLeading)
        #expect(focalAlignment(x: 0.33, y: 1.0) == .bottomLeading)
        #expect(focalAlignment(x: 0.34, y: 0.67) == .bottom)
        #expect(focalAlignment(x: 0.5, y: 0.9) == .bottom)
        #expect(focalAlignment(x: 0.66, y: 1.0) == .bottom)
        #expect(focalAlignment(x: 0.67, y: 0.67) == .bottomTrailing)
        #expect(focalAlignment(x: 1.0, y: 1.0) == .bottomTrailing)
    }

    @Test("focalAnchorPoint clamps x and y coordinates to [0, 1] unit range")
    func focalAnchorPointClamping() {
        #expect(focalAnchorPoint(x: 0.5, y: 0.5) == UnitPoint(x: 0.5, y: 0.5))
        #expect(focalAnchorPoint(x: -0.2, y: 1.5) == UnitPoint(x: 0.0, y: 1.0))
        #expect(focalAnchorPoint(x: 1.2, y: -0.5) == UnitPoint(x: 1.0, y: 0.0))
    }


    // MARK: - 5. Theme Switching

    @Test("theme mediaURL resolution respects light vs dark modes and empty fallbacks")
    func themeMediaURLResolution() {
        let sourceWithBoth = CampaignCanvasMediaSource(
            url: "https://example.invalid/light.png",
            darkUrl: "https://example.invalid/dark.png",
            placeholder: nil
        )
        #expect(
            CampaignCanvasTheme.shared.mediaURL(sourceWithBoth, isDark: false)
                == "https://example.invalid/light.png"
        )
        #expect(
            CampaignCanvasTheme.shared.mediaURL(sourceWithBoth, isDark: true)
                == "https://example.invalid/dark.png"
        )

        let sourceWithNilDark = CampaignCanvasMediaSource(
            url: "https://example.invalid/light.png",
            darkUrl: nil,
            placeholder: nil
        )
        #expect(
            CampaignCanvasTheme.shared.mediaURL(sourceWithNilDark, isDark: false)
                == "https://example.invalid/light.png"
        )
        #expect(
            CampaignCanvasTheme.shared.mediaURL(sourceWithNilDark, isDark: true)
                == "https://example.invalid/light.png"
        )

        let sourceWithEmptyDark = CampaignCanvasMediaSource(
            url: "https://example.invalid/light.png",
            darkUrl: "",
            placeholder: nil
        )
        #expect(
            CampaignCanvasTheme.shared.mediaURL(sourceWithEmptyDark, isDark: true)
                == "https://example.invalid/light.png"
        )
    }

    // MARK: - 8. BlurHash Algorithmic Oracle

    @Test("BlurHashDecoder decodes valid hashes and rejects malformed inputs deterministically")
    func blurHashDecoderOracle() {
        let validHash = "LEHLk~WB2yk8pyo0adR*.7kCMdnj"

        // 1. Valid hash decodes to exact dimensions
        let decoded = BlurHashDecoder.decode(validHash, width: 32, height: 32)
        #expect(decoded != nil)
        #expect(decoded?.size.width == 32)
        #expect(decoded?.size.height == 32)

        // 2. Punch parameter adjustments
        let punched = BlurHashDecoder.decode(validHash, width: 16, height: 16, punch: 2.0)
        #expect(punched != nil)
        #expect(punched?.size.width == 16)
        #expect(punched?.size.height == 16)

        // 3. Degenerate dimension boundaries return nil
        #expect(BlurHashDecoder.decode(validHash, width: 0, height: 32) == nil)
        #expect(BlurHashDecoder.decode(validHash, width: 32, height: 0) == nil)
        #expect(BlurHashDecoder.decode(validHash, width: -5, height: 32) == nil)

        // 4. Insufficient length (< 6 characters) returns nil
        #expect(BlurHashDecoder.decode("", width: 32, height: 32) == nil)
        #expect(BlurHashDecoder.decode("LEHLk", width: 32, height: 32) == nil)

        // 5. Invalid characters outside base83 alphabet return nil
        #expect(BlurHashDecoder.decode("LEHLk~WB2yk8pyo0adR*!7kCMdnj", width: 32, height: 32) == nil)

        // 6. Truncated or mismatched component length returns nil
        #expect(BlurHashDecoder.decode("LEHLk~WB2yk8pyo0", width: 32, height: 32) == nil)
    }

    // MARK: - 9. Anchorless Design Scale Oracle

    @Test("anchorlessDesignScale computes exact scale ratio with finite and positive bounds checking")
    func anchorlessDesignScaleOracle() {
        // Standard positive finite values compute ratio, capped at maxFloatingCanvasUpscale (1.15)
        #expect(anchorlessDesignScale(hostWidth: 375, designWidth: 375) == 1.0)
        #expect(anchorlessDesignScale(hostWidth: 187.5, designWidth: 375) == 0.5)
        #expect(anchorlessDesignScale(hostWidth: 412.5, designWidth: 375) == 1.1)
        // Upscale above 1.15 is clamped to maxFloatingCanvasUpscale (1.15)
        #expect(anchorlessDesignScale(hostWidth: 750, designWidth: 375) == 1.15)

        // Zero dimensions return nil
        #expect(anchorlessDesignScale(hostWidth: 0, designWidth: 375) == nil)
        #expect(anchorlessDesignScale(hostWidth: 375, designWidth: 0) == nil)

        // Negative dimensions return nil
        #expect(anchorlessDesignScale(hostWidth: -100, designWidth: 375) == nil)
        #expect(anchorlessDesignScale(hostWidth: 375, designWidth: -100) == nil)

        // Non-finite dimensions (NaN, infinity) return nil
        #expect(anchorlessDesignScale(hostWidth: .nan, designWidth: 375) == nil)
        #expect(anchorlessDesignScale(hostWidth: 375, designWidth: .infinity) == nil)
        #expect(anchorlessDesignScale(hostWidth: .infinity, designWidth: 375) == nil)
    }

    @Test("empty or invalid image URL renders placeholder rather than blank view", arguments: ["", "http://[invalid"])
    func emptyOrInvalidImageURLRendersPlaceholder(url: String) {
        let widget = imageWidget(url: url)
        let window = mount(image: widget)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.05)
        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        #expect(Self.hasMoreThanOneColor(image))
    }

    // MARK: - 13. Visual Golden

    @Test("image renderer matches visual golden", .tags(.golden)) @MainActor
    func imageRendererVisualGolden() throws {
        let testURL = try prewarmedAssetURL(named: "cloudinary-whatsapp.jpg")

        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 220,
            "background": [
                "type": "solid",
                "color": "#F3F4F6"
            ],
            "children": [
                [
                    "kind": "widget",
                    "id": "img1",
                    "rect": ["x": 0.05, "y": 0.05, "width": 0.9, "height": 0.9],
                    "widget": [
                        "type": "digia/image",
                        "containerProps": [
                            "cornerRadius": ["topLeft": 16, "topRight": 16, "bottomRight": 16, "bottomLeft": 16],
                            "border": ["color": "#E5E7EB", "width": 1],
                            "shadow": [
                                "color": "#1A000000",
                                "blur": 8,
                                "spread": 0,
                                "offsetX": 0,
                                "offsetY": 2
                            ]
                        ],
                        "props": [
                            "source": [
                                "url": testURL
                            ],
                            "fit": "cover",
                            "positionX": 0.5,
                            "positionY": 0.5,
                            "scale": 1.0
                        ]
                    ]
                ]
            ]
        ])

        assertCanvasVisualGolden(canvas: canvas)
    }

    @Test("image renderer handles aspect fit contain within styled container", .tags(.golden)) @MainActor
    func imageRendererFitContainVisualGolden() throws {
        let testURL = try prewarmedAssetURL(named: "strawberry.jpg")

        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 220,
            "background": [
                "type": "solid",
                "color": "#0F172A"
            ],
            "children": [
                [
                    "kind": "widget",
                    "id": "contain-img",
                    "rect": ["x": 0.05, "y": 0.08, "width": 0.9, "height": 0.84],
                    "widget": [
                        "type": "digia/image",
                        "containerProps": [
                            "fill": ["type": "solid", "color": "#1E293B"],
                            "borderRadius": 16,
                            "border": ["color": "#38BDF8", "width": 2],
                            "shadow": [
                                "color": "#40000000",
                                "blur": 12,
                                "spread": 0,
                                "offsetX": 0,
                                "offsetY": 4
                            ]
                        ],
                        "props": [
                            "source": [
                                "url": testURL
                            ],
                            "fit": "contain",
                            "positionX": 0.5,
                            "positionY": 0.5,
                            "scale": 1.0
                        ]
                    ]
                ]
            ]
        ])

        assertCanvasVisualGolden(canvas: canvas)
    }

    @Test("image renderer handles template tintColor styling", .tags(.golden)) @MainActor
    func imageRendererTintColorVisualGolden() throws {
        let testURL = try prewarmedAssetURL(named: "tint-star-icon.png")

        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 200,
            "background": [
                "type": "solid",
                "color": "#FFF1F2"
            ],
            "children": [
                [
                    "kind": "widget",
                    "id": "tinted-img",
                    "rect": ["x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8],
                    "widget": [
                        "type": "digia/image",
                        "containerProps": [
                            "fill": ["type": "solid", "color": "#FFFFFFFF"],
                            "borderRadius": 16,
                            "border": ["color": "#FB7185", "width": 1.5],
                            "shadow": [
                                "color": "#20E11D48",
                                "blur": 10,
                                "spread": 0,
                                "offsetX": 0,
                                "offsetY": 3
                            ]
                        ],
                        "props": [
                            "source": [
                                "url": testURL
                            ],
                            "fit": "contain",
                            "tintColor": "#E11D48",
                            "positionX": 0.5,
                            "positionY": 0.5,
                            "scale": 1.0
                        ]
                    ]
                ]
            ]
        ])

        assertCanvasVisualGolden(canvas: canvas)
    }

    @Test("image renderer handles asymmetric corner geometry with border stroke", .tags(.golden)) @MainActor
    func imageRendererAsymmetricCornersVisualGolden() throws {
        let testURL = try prewarmedAssetURL(named: "cloudinary-whatsapp.jpg")

        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 220,
            "background": [
                "type": "solid",
                "color": "#F8FAFC"
            ],
            "children": [
                [
                    "kind": "widget",
                    "id": "asymm-img",
                    "rect": ["x": 0.08, "y": 0.08, "width": 0.84, "height": 0.84],
                    "widget": [
                        "type": "digia/image",
                        "containerProps": [
                            "cornerRadius": ["topLeft": 32, "topRight": 6, "bottomRight": 32, "bottomLeft": 6],
                            "border": ["color": "#059669", "width": 2.5],
                            "shadow": [
                                "color": "#25000000",
                                "blur": 14,
                                "spread": 0,
                                "offsetX": 0,
                                "offsetY": 6
                            ]
                        ],
                        "props": [
                            "source": [
                                "url": testURL
                            ],
                            "fit": "cover",
                            "positionX": 0.5,
                            "positionY": 0.5,
                            "scale": 1.0
                        ]
                    ]
                ]
            ]
        ])

        assertCanvasVisualGolden(canvas: canvas)
    }

    @Test(
        "empty or invalid image URL shows labelled placeholder visual golden",
        .tags(.golden),
        arguments: ["", "http://[invalid"]
    )
    func emptyOrInvalidImageURLVisualGolden(url: String) {
        let widget = imageWidget(url: url)
        let window = mount(image: widget)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)
        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        #expect(Self.hasMoreThanOneColor(image))
        assertVisualGolden(
            matching: image,
            precision: 0.999,
            perceptualPrecision: 0.98,
            named: url.isEmpty ? "empty" : "invalid"
        )
    }

    private func prewarmedAssetURL(named fileName: String) throws -> String {
        try #require(ComponentTestHost.prewarmAssetImage(named: fileName))
        guard let workspaceUrl = FixtureLoader.workspaceURL() else {
            Issue.record("Workspace URL not available")
            throw ImageTestError.missingWidget
        }
        let assetOrigin = workspaceUrl.appendingPathComponent("testkit/mock-server").absoluteString
        let cleanOrigin = assetOrigin.hasSuffix("/") ? String(assetOrigin.dropLast()) : assetOrigin
        return "\(cleanOrigin)/assets/\(fileName)"
    }

    private func mount(
        canvas: CampaignCanvas,
        isDark: Bool? = nil,
        variables: VariableContext? = nil
    ) -> (UIWindow, UIHostingController<AnyView>) {
        ComponentTestHost.mountCanvas(canvas, isDark: isDark, variables: variables)
    }

    private func assertCanvasVisualGolden(
        canvas: CampaignCanvas,
        function: StaticString = #function
    ) {
        let (window, controller) = mount(canvas: canvas)
        defer { unmount(window) }

        ComponentTestHost.drainRunLoop(for: 0.5)
        controller.overrideUserInterfaceStyle = .dark
        ComponentTestHost.drainRunLoop(for: 0.4)
        controller.overrideUserInterfaceStyle = .light
        ComponentTestHost.drainRunLoop(for: 0.5)
        window.layoutIfNeeded()

        let image = ComponentTestHost.renderImage(of: controller.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98, function: function)
    }

    // MARK: - Helpers

    private func parsedImage(_ props: [String: Any]) throws -> CampaignCanvasWidget {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 320,
            "canvasHeight": 200,
            "children": [[
                "kind": "widget",
                "id": "image",
                "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
                "widget": ["type": "digia/image", "props": props],
            ]],
        ])
        guard case .widget(_, _, let widget) = canvas.children.first else {
            throw ImageTestError.missingWidget
        }
        return widget
    }

    private func imageWidget(
        url: String = "https://example.invalid/image.png",
        darkURL: String? = nil,
        placeholder: ImagePlaceholder? = nil,
        fit: String = "contain",
        positionX: CGFloat = 0.5,
        positionY: CGFloat = 0.5,
        scale: CGFloat = 1.0,
        tint: CampaignColor? = nil
    ) -> CampaignCanvasWidget {
        .image(
            box: .none,
            source: CampaignCanvasMediaSource(url: url, darkUrl: darkURL, placeholder: placeholder),
            fit: fit,
            positionX: positionX,
            positionY: positionY,
            scale: scale,
            tintColor: tint
        )
    }

    private func mount(
        image: CampaignCanvasWidget,
        isDark: Bool = false,
        variables: VariableContext? = nil
    ) -> UIWindow {
        let canvas = CampaignCanvas(
            version: 2,
            width: 320,
            height: 200,
            background: .solid(.literal("#FFFFFFFF")),
            children: [
                .widget(
                    id: "image",
                    rect: CampaignCanvasRect(x: 0, y: 0, width: 320, height: 200),
                    widget: image
                )
            ]
        )
        let (window, _) = mount(canvas: canvas, isDark: isDark, variables: variables)
        return window
    }

    private static func hasMoreThanOneColor(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return false }
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 3)
        let first = (bytes[0], bytes[1], bytes[2])
        for pixel in stride(from: 0, to: cgImage.width * cgImage.height, by: 97) {
            let offset = pixel * bytesPerPixel
            if (bytes[offset], bytes[offset + 1], bytes[offset + 2]) != first { return true }
        }
        return false
    }

    private func mount<Content: View>(_ controller: UIHostingController<Content>) -> UIWindow {
        ComponentTestHost.mount(controller)
    }

    private func unmount(_ window: UIWindow) {
        ComponentTestHost.unmount(window)
    }
}

private enum ImageTestError: Error {
    case missingWidget
}
