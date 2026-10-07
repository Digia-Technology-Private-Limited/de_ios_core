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

    // MARK: - 3. Shadow Blur & Spread Calculation

    @Test("nativeContentBlurRadius calculates Gaussian sigma with spread and non-negative clamping")
    func nativeContentBlurRadiusMath() {
        // Zero blur produces zero sigma; spread passes through or clamps to 0
        let zeroBlurZeroSpread = CampaignCanvasShadow(
            color: .literal("#FF000000"), blur: 0, spread: 0, offsetX: 0, offsetY: 0)
        #expect(zeroBlurZeroSpread.nativeContentBlurRadius == 0)

        let zeroBlurPositiveSpread = CampaignCanvasShadow(
            color: .literal("#FF000000"), blur: 0, spread: 4, offsetX: 0, offsetY: 0)
        #expect(zeroBlurPositiveSpread.nativeContentBlurRadius == 4)

        let zeroBlurNegativeSpread = CampaignCanvasShadow(
            color: .literal("#FF000000"), blur: 0, spread: -3, offsetX: 0, offsetY: 0)
        #expect(zeroBlurNegativeSpread.nativeContentBlurRadius == 0)

        // Positive blur: blur * 0.57735 + 0.5
        let positiveBlur = CampaignCanvasShadow(
            color: .literal("#FF000000"), blur: 10, spread: 0, offsetX: 0, offsetY: 0)
        let expectedSigma = 10.0 * 0.57735 + 0.5
        #expect(abs(positiveBlur.nativeContentBlurRadius - expectedSigma) < 0.0001)

        let positiveBlurWithSpread = CampaignCanvasShadow(
            color: .literal("#FF000000"), blur: 10, spread: 2, offsetX: 0, offsetY: 0)
        #expect(abs(positiveBlurWithSpread.nativeContentBlurRadius - (expectedSigma + 2.0)) < 0.0001)

        let positiveBlurNegativeSpreadClamped = CampaignCanvasShadow(
            color: .literal("#FF000000"), blur: 4, spread: -20, offsetX: 0, offsetY: 0)
        #expect(positiveBlurNegativeSpreadClamped.nativeContentBlurRadius == 0)
    }

    // MARK: - 4. Visible Surface Detection

    @Test("hasVisibleSurface accurately differentiates opaque surfaces from transparent cutouts")
    func visibleSurfaceDetection() {
        // Solid fill with alpha > 0
        let solidOpaque = CampaignCanvasBox(fill: .solid(.literal("#FFFFFFFF")))
        #expect(solidOpaque.hasVisibleSurface(isDark: false))

        // Solid fill with alpha == 0
        let solidTransparent = CampaignCanvasBox(fill: .solid(.literal("#00000000")))
        #expect(!solidTransparent.hasVisibleSurface(isDark: false))

        // No fill, no border
        let noFillNoBorder = CampaignCanvasBox(fill: .none, border: nil)
        #expect(!noFillNoBorder.hasVisibleSurface(isDark: false))

        // No fill, with opaque border
        let noFillOpaqueBorder = CampaignCanvasBox(
            fill: .none,
            border: CampaignCanvasBorder(color: .literal("#FF0000FF"), width: 2)
        )
        #expect(noFillOpaqueBorder.hasVisibleSurface(isDark: false))

        // No fill, zero width border
        let noFillZeroWidthBorder = CampaignCanvasBox(
            fill: .none,
            border: CampaignCanvasBorder(color: .literal("#FF0000FF"), width: 0)
        )
        #expect(!noFillZeroWidthBorder.hasVisibleSurface(isDark: false))

        // No fill, transparent border color
        let noFillTransparentBorder = CampaignCanvasBox(
            fill: .none,
            border: CampaignCanvasBorder(color: .literal("#00000000"), width: 2)
        )
        #expect(!noFillTransparentBorder.hasVisibleSurface(isDark: false))

        // Gradients always count as visible surface
        let gradFill = CampaignCanvasBox(
            fill: .gradient(
                type: .linear,
                angleDegrees: 45,
                centerX: 0.5,
                centerY: 0.5,
                radius: 1,
                startAngleDegrees: 0,
                endAngleDegrees: 360,
                stops: [CampaignCanvasGradientStop(color: .literal("#FFFFFFFF"), offset: 0)]
            )
        )
        #expect(gradFill.hasVisibleSurface(isDark: false))

        // Image fill counts as visible surface
        let imageFill = CampaignCanvasBox(
            fill: .image(
                source: CampaignCanvasMediaSource(
                    url: "https://example.invalid/bg.png",
                    darkUrl: nil,
                    placeholder: nil
                ),
                positionX: 0.5,
                positionY: 0.5,
                scale: 1
            )
        )
        #expect(imageFill.hasVisibleSurface(isDark: false))
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

    // MARK: - 6. Variable Interpolation

    @Test("variable interpolation resolves tokens in image URLs")
    func variableInterpolationInImageURL() {
        let template = "https://cdn.example.invalid/products/{{sku}}/hero_{{size}}.jpg"
        let context = VariableContext(
            values: [
                "sku": "PROD-998",
                "size": "large",
            ],
            types: [
                "sku": "string",
                "size": "string",
            ]
        )

        let resolved = interpolate(template, context: context)
        #expect(resolved == "https://cdn.example.invalid/products/PROD-998/hero_large.jpg")

        let noTokens = "https://cdn.example.invalid/products/static.png"
        #expect(interpolate(noTokens, context: context) == noTokens)

        let missingToken = "https://cdn.example.invalid/{{missing}}/photo.png"
        #expect(interpolate(missingToken, context: context) == "https://cdn.example.invalid//photo.png")
    }

    // MARK: - 7. SDImageCache Prewarming & Component Mounting

    @Test("prewarmed image renders synchronously through SDImageCache memory hit")
    func prewarmedSDImageCacheHit() {
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        let testImage = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        let testURL = "https://example.invalid/prewarmed-blue.png"
        SDImageCache.shared.store(testImage, forKey: testURL, toDisk: false)
        #expect(SDImageCache.shared.imageFromMemoryCache(forKey: testURL) != nil)

        let widget = imageWidget(url: testURL, fit: "contain")
        let window = mount(image: widget)
        ComponentTestHost.drainRunLoop(for: 0.1)

        #expect(window.rootViewController?.view != nil)
        unmount(window)
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

    @Test("empty or invalid image URL renders placeholder cleanly without crashing")
    func emptyOrInvalidImageURLFallback() {
        let placeholder = ImagePlaceholder(
            type: .blurhash,
            blurHash: "LEHLk~WB2yk8pyo0adR*.7kCMdnj"
        )

        for emptyURL in ["", "   ", "invalid-non-url"] {
            let widget = imageWidget(url: emptyURL, placeholder: placeholder)
            let window = mount(image: widget)
            ComponentTestHost.drainRunLoop(for: 0.05)

            #expect(window.rootViewController?.view != nil)
            unmount(window)
        }
    }

    @Test("dynamic theme change updates image renderer cleanly")
    func dynamicThemeSwitching() {
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        let lightImg = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let darkImg = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        let lightURL = "https://example.invalid/dynamic-light.png"
        let darkURL = "https://example.invalid/dynamic-dark.png"
        SDImageCache.shared.store(lightImg, forKey: lightURL, toDisk: false)
        SDImageCache.shared.store(darkImg, forKey: darkURL, toDisk: false)

        let widget = imageWidget(url: lightURL, darkURL: darkURL)
        let theme = ImageThemeDriver()
        let harness = ImageThemeHarness(image: widget, theme: theme)
        let window = mount(harness: harness)

        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(window.rootViewController?.view != nil)

        theme.isDark = true
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(window.rootViewController?.view != nil)

        unmount(window)
    }

    @Test("image with tint color applies template rendering without crashing")
    func imageWithTintColor() {
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        let testImage = renderer.image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        let testURL = "https://example.invalid/tinted-asset.png"
        SDImageCache.shared.store(testImage, forKey: testURL, toDisk: false)

        let widget = imageWidget(url: testURL, tint: .literal("#FF00FF00"))
        let window = mount(image: widget)
        ComponentTestHost.drainRunLoop(for: 0.05)

        #expect(window.rootViewController?.view != nil)
        unmount(window)
    }

    // MARK: - 13. Visual Golden

    @Test("image renderer matches visual golden", .tags(.golden)) @MainActor
    func imageRendererVisualGolden() throws {
        try #require(ComponentTestHost.prewarmAssetImage(named: "cloudinary-whatsapp.jpg"))
        guard let workspaceUrl = FixtureLoader.workspaceURL() else {
            Issue.record("Workspace URL not available")
            return
        }
        let assetOrigin = workspaceUrl.appendingPathComponent("testkit/mock-server").absoluteString
        let cleanOrigin = assetOrigin.hasSuffix("/") ? String(assetOrigin.dropLast()) : assetOrigin
        let testURL = "\(cleanOrigin)/assets/cloudinary-whatsapp.jpg"

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

        let config = InlineCanvasConfig(
            slotKey: "canvas_image_renderer_golden_slot",
            designWidth: 360,
            cornerRadius: 0,
            margin: InlineCanvasMargin(),
            canvas: canvas
        )
        let hostView = ComponentTestHost.makeCanvasSlotHost(
            config: config,
            slotWidth: 360,
            drainDuration: 1.0,
            rendersLoadedMedia: true
        )
        defer { ComponentTestHost.cleanupCanvasSlotHost(hostView, slotKey: config.slotKey) }

        let image = ComponentTestHost.renderImage(of: hostView)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
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
        var stage = CampaignCanvasStage(
            canvas: canvas,
            authoredCornerRadius: 0,
            isDark: isDark,
            showBackground: true,
            onAction: { _ in }
        )
        stage.animateWidgetsOnAppear = false
        let root = AnyView(
            stage
                .environment(\.digiaVariables, variables)
        )
        return mount(
            ComponentTestHost.makeComponentHost(
                rootView: root,
                size: CGSize(width: 320, height: 200),
                backgroundColor: .white
            )
        )
    }

    private func mount(harness: ImageThemeHarness) -> UIWindow {
        mount(
            ComponentTestHost.makeComponentHost(
                rootView: AnyView(harness),
                size: CGSize(width: 320, height: 200),
                backgroundColor: .white
            )
        )
    }

    private func mount<Content: View>(_ controller: UIHostingController<Content>) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: controller.view.bounds)
        }
        window.frame = controller.view.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        ComponentTestHost.drainRunLoop(for: 0.05)
        return window
    }

    private func unmount(_ window: UIWindow) {
        if let root = window.rootViewController {
            root.beginAppearanceTransition(false, animated: false)
            root.endAppearanceTransition()
        }
        window.rootViewController = nil
        window.isHidden = true
        window.resignKey()
        ComponentTestHost.drainRunLoop(for: 0.02)
    }
}

@MainActor
private final class ImageThemeDriver: ObservableObject {
    @Published var isDark = false
}

private struct ImageThemeHarness: View {
    let image: CampaignCanvasWidget
    @ObservedObject var theme: ImageThemeDriver

    var body: some View {
        var stage = CampaignCanvasStage(
            canvas: CampaignCanvas(
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
            ),
            authoredCornerRadius: 0,
            isDark: theme.isDark,
            showBackground: true,
            onAction: { _ in }
        )
        stage.animateWidgetsOnAppear = false
        return stage
    }
}

private enum ImageTestError: Error {
    case missingWidget
}
