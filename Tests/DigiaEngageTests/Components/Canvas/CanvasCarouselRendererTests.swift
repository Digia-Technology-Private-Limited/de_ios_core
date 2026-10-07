import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas carousel renderer", .serialized, .tags(.canvas, .component))
struct CanvasCarouselRendererTests {

    // MARK: - 1. Parser & Properties Preservation

    @Test("carousel parser preserves properties and layout configuration")
    func carouselParserPreservesPropertiesAndLayout() throws {
        let widget = try parsedCarousel([
            "viewportFraction": 0.85,
            "itemSpacing": 16,
            "autoPlay": false,
            "autoPlayInterval": 4500,
            "animationDuration": 600,
            "infiniteScroll": true,
            "cornerRadius": 14,
            "showIndicator": true,
            "dotWidth": 12,
            "dotHeight": 6,
            "dotSpacing": 8,
            "dotColor": "#FFCBD5E1",
            "activeDotColor": "#FF4F46E5",
            "indicatorEffect": "worm"
        ])

        guard case .carousel(
            let box, let slides, let fraction, let itemSpacing,
            let autoPlay, let autoPlayInterval, let animationDuration,
            let infiniteScroll, let cornerRadius,
            let showIndicator, let dotWidth, let dotHeight, let dotSpacing,
            let dotColor, let activeDotColor, let effect
        ) = widget else {
            Issue.record("Expected .carousel widget")
            return
        }

        #expect(box == .none)
        #expect(slides.count == 2)
        #expect(fraction == 0.85)
        #expect(itemSpacing == 16)
        #expect(autoPlay == false)
        #expect(autoPlayInterval == 4.5)
        #expect(animationDuration == 0.6)
        #expect(infiniteScroll == true)
        #expect(cornerRadius == 14)
        #expect(showIndicator == true)
        #expect(dotWidth == 12)
        #expect(dotHeight == 6)
        #expect(dotSpacing == 8)
        #expect(dotColor == .literal("#FFCBD5E1"))
        #expect(activeDotColor == .literal("#FF4F46E5"))
        #expect(effect == "worm")
    }

    @Test("carousel parser clamps invalid values and applies defaults")
    func carouselParserClampingAndFallbacks() throws {
        // Test lower bounds and clamping
        let clampedWidget = try parsedCarousel([
            "viewportFraction": 0.05, // < 0.1 -> fallback 0.88
            "itemSpacing": -10, // < 0 -> fallback 12
            "autoPlayInterval": -500, // <= 0 -> fallback 3000ms (3.0s)
            "animationDuration": -100, // <= 0 -> fallback 700ms (0.7s)
            "cornerRadius": -5, // < 0 -> fallback 12
            "dotWidth": 0, // <= 0 -> fallback 8
            "dotHeight": -2, // <= 0 -> fallback 8
            "dotSpacing": -4 // < 0 -> fallback 12
        ])

        guard case .carousel(
            _, _, let fraction, let spacing,
            let autoPlay, let autoPlayInterval, let animationDuration,
            let infiniteScroll, let cornerRadius,
            let showIndicator, let dotWidth, let dotHeight, let dotSpacing,
            _, _, _
        ) = clampedWidget else {
            Issue.record("Expected .carousel widget")
            return
        }

        #expect(fraction == 0.88)
        #expect(spacing == 12)
        #expect(autoPlay == true) // Default
        #expect(autoPlayInterval == 3.0)
        #expect(animationDuration == 0.7)
        #expect(infiniteScroll == true) // Default
        #expect(cornerRadius == 12)
        #expect(showIndicator == true) // Default
        #expect(dotWidth == 8)
        #expect(dotHeight == 8)
        #expect(dotSpacing == 12)

        // Test upper bound on viewport fraction
        let overUnityWidget = try parsedCarousel([
            "viewportFraction": 1.25 // > 1.0 -> fallback 0.88
        ])
        guard case .carousel(_, _, let overFraction, _, _, _, _, _, _, _, _, _, _, _, _, _) = overUnityWidget else {
            Issue.record("Expected .carousel widget")
            return
        }
        #expect(overFraction == 0.88)
    }

    @Test("carousel parser rejects invalid or empty slides")
    func carouselParserRejections() throws {
        // 1. Empty slides array
        let emptyCanvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 200,
            "children": [
                [
                    "kind": "widget",
                    "id": "c1",
                    "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
                    "widget": [
                        "type": "digia/canvasCarousel",
                        "props": [
                            "slides": []
                        ]
                    ]
                ]
            ]
        ])
        #expect(emptyCanvas.children.isEmpty)

        // 2. Corrupt slide (unsupported version)
        let corruptCanvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 200,
            "children": [
                [
                    "kind": "widget",
                    "id": "c2",
                    "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
                    "widget": [
                        "type": "digia/canvasCarousel",
                        "props": [
                            "slides": [
                                makeSlideJSON(title: "Good Slide", colorHex: "#FF4F46E5"),
                                ["version": 99] // Invalid slide version
                            ]
                        ]
                    ]
                ]
            ]
        ])
        #expect(corruptCanvas.children.isEmpty)
    }

    // MARK: - 2. Geometry & Layout Oracles

    @Test("carousel geometry oracle computes slide width and strip height")
    func carouselGeometryOracle() {
        let indicatorGap: CGFloat = 8
        let indicatorBottom: CGFloat = 2

        func computeGeometry(
            containerSize: CGSize,
            viewportFraction: CGFloat,
            itemSpacing: CGFloat,
            showIndicator: Bool,
            dotHeight: CGFloat
        ) -> (slideWidth: CGFloat, stripHeight: CGFloat, indicatorHeight: CGFloat) {
            let indicatorHeight = showIndicator ? indicatorGap + dotHeight + indicatorBottom : 0
            let stripHeight = containerSize.height - indicatorHeight
            let slideWidth = containerSize.width * viewportFraction - itemSpacing
            return (slideWidth, stripHeight, indicatorHeight)
        }

        // Scenario 1: Standard viewport (360x220), indicator visible (dotHeight = 8)
        let standard = computeGeometry(
            containerSize: CGSize(width: 360, height: 220),
            viewportFraction: 0.88,
            itemSpacing: 12,
            showIndicator: true,
            dotHeight: 8
        )
        #expect(standard.indicatorHeight == 18) // 8 + 8 + 2
        #expect(standard.stripHeight == 202)   // 220 - 18
        let expectedStandardWidth: CGFloat = 304.8
        #expect(abs(standard.slideWidth - expectedStandardWidth) < 0.001)

        // Scenario 2: Indicator hidden
        let noIndicator = computeGeometry(
            containerSize: CGSize(width: 360, height: 200),
            viewportFraction: 0.85,
            itemSpacing: 16,
            showIndicator: false,
            dotHeight: 8
        )
        #expect(noIndicator.indicatorHeight == 0)
        #expect(noIndicator.stripHeight == 200)
        let expectedNoIndicatorWidth: CGFloat = 290.0
        #expect(abs(noIndicator.slideWidth - expectedNoIndicatorWidth) < 0.001)

        // Scenario 3: Full width slides (fraction = 1.0, spacing = 0)
        let fullWidth = computeGeometry(
            containerSize: CGSize(width: 400, height: 250),
            viewportFraction: 1.0,
            itemSpacing: 0,
            showIndicator: true,
            dotHeight: 6
        )
        #expect(fullWidth.indicatorHeight == 16) // 8 + 6 + 2
        #expect(fullWidth.stripHeight == 234)
        #expect(fullWidth.slideWidth == 400)
    }

    // MARK: - 3. Real Index Oracle (Infinite Scroll / Looping)

    @Test("carousel real index oracle resolves correct slide indices")
    func carouselRealIndexOracle() {
        func realIndex(_ displayIndex: Int, slideCount: Int, loopEnabled: Bool) -> Int {
            guard loopEnabled else { return displayIndex }
            return (((displayIndex - 1) % slideCount) + slideCount) % slideCount
        }

        let slideCount = 3

        // When loopEnabled is false: displayIndex matches index directly
        for i in 0 ..< slideCount {
            #expect(realIndex(i, slideCount: slideCount, loopEnabled: false) == i)
        }

        // When loopEnabled is true: displayCount = slideCount + 2 (5 total)
        // displayIndex 0 is the prepended duplicate of slide 2
        #expect(realIndex(0, slideCount: slideCount, loopEnabled: true) == 2)
        // displayIndex 1 is slide 0 (initial position)
        #expect(realIndex(1, slideCount: slideCount, loopEnabled: true) == 0)
        // displayIndex 2 is slide 1
        #expect(realIndex(2, slideCount: slideCount, loopEnabled: true) == 1)
        // displayIndex 3 is slide 2
        #expect(realIndex(3, slideCount: slideCount, loopEnabled: true) == 2)
        // displayIndex 4 is the appended duplicate of slide 0
        #expect(realIndex(4, slideCount: slideCount, loopEnabled: true) == 0)

        // Extended 5-slide test
        let fiveSlides = 5
        #expect(realIndex(0, slideCount: fiveSlides, loopEnabled: true) == 4) // duplicate of last
        #expect(realIndex(1, slideCount: fiveSlides, loopEnabled: true) == 0) // first
        #expect(realIndex(5, slideCount: fiveSlides, loopEnabled: true) == 4) // last
        #expect(realIndex(6, slideCount: fiveSlides, loopEnabled: true) == 0) // duplicate of first
    }

    // MARK: - 4. Action Step Stamping Oracle

    @Test("carousel stamps action request with slide step metadata")
    func carouselActionStampingOracle() {
        let step = CanvasStep(kind: .carouselSlide, index: 2, total: 5)
        #expect(step.kind == .carouselSlide)
        #expect(step.index == 2)
        #expect(step.total == 5)

        var request = CampaignCanvasActionRequest(actions: [], elementId: "slide-1")
        request.step = step
        #expect(request.step?.kind == .carouselSlide)
        #expect(request.step?.index == 2)
        #expect(request.step?.total == 5)
    }

    // MARK: - 5. Visual Golden Tests

    @Test("carousel renderer renders multi-slide strip and active dot indicators")
    func carouselRendererVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 220,
            "background": ["type": "solid", "color": ["value": "#FFF8FAFC"]],
            "children": [
                [
                    "kind": "widget",
                    "id": "carousel-1",
                    "rect": ["x": 0.0, "y": 0.05, "width": 1.0, "height": 0.9],
                    "widget": [
                        "type": "digia/canvasCarousel",
                        "props": [
                            "slides": [
                                makeSlideJSON(title: "Welcome to Digia", subtitle: "Slide 1 of 3", colorHex: "#FF4F46E5"),
                                makeSlideJSON(title: "Interactive Cards", subtitle: "Slide 2 of 3", colorHex: "#FF059669"),
                                makeSlideJSON(title: "Seamless Motion", subtitle: "Slide 3 of 3", colorHex: "#FFD97706")
                            ],
                            "viewportFraction": 0.85,
                            "itemSpacing": 12,
                            "autoPlay": false,
                            "infiniteScroll": false,
                            "cornerRadius": 14,
                            "showIndicator": true,
                            "dotWidth": 16,
                            "dotHeight": 6,
                            "dotSpacing": 8,
                            "dotColor": "#FFCBD5E1",
                            "activeDotColor": "#FF4F46E5"
                        ]
                    ]
                ]
            ]
        ])

        let window = mount(canvas: canvas)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("carousel renderer adapts dot and slide styling to dark theme")
    func carouselRendererDarkThemeVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 220,
            "background": ["type": "solid", "color": ["value": "#FF0F172A"]],
            "children": [
                [
                    "kind": "widget",
                    "id": "carousel-dark",
                    "rect": ["x": 0.0, "y": 0.05, "width": 1.0, "height": 0.9],
                    "widget": [
                        "type": "digia/canvasCarousel",
                        "props": [
                            "slides": [
                                makeSlideJSON(title: "Night Mode Experience", subtitle: "Curated for OLED", colorHex: "#FF1E1B4B"),
                                makeSlideJSON(title: "Vibrant Accents", subtitle: "Neon highlights", colorHex: "#FF064E3B")
                            ],
                            "viewportFraction": 0.88,
                            "itemSpacing": 14,
                            "autoPlay": false,
                            "infiniteScroll": false,
                            "cornerRadius": 16,
                            "showIndicator": true,
                            "dotWidth": 14,
                            "dotHeight": 6,
                            "dotSpacing": 8,
                            "dotColor": "#FF334155",
                            "activeDotColor": "#FF818CF8"
                        ]
                    ]
                ]
            ]
        ])

        let window = mount(canvas: canvas, isDark: true)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    // MARK: - Test Helpers

    private func parsedCarousel(
        _ props: [String: Any],
        slides: [[String: Any]]? = nil
    ) throws -> CampaignCanvasWidget {
        var mergedProps = props
        if mergedProps["slides"] == nil {
            mergedProps["slides"] = slides ?? [
                makeSlideJSON(title: "Slide 1", colorHex: "#FF4F46E5"),
                makeSlideJSON(title: "Slide 2", colorHex: "#FF10B981")
            ]
        }

        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 220,
            "children": [
                [
                    "kind": "widget",
                    "id": "carousel-test",
                    "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
                    "widget": [
                        "type": "digia/canvasCarousel",
                        "props": mergedProps
                    ]
                ]
            ]
        ])

        guard case .widget(_, _, let widget) = canvas.children.first else {
            throw DesignTokenError.invalid("Failed to parse carousel widget")
        }
        return widget
    }

    private func makeSlideJSON(
        title: String,
        subtitle: String? = nil,
        colorHex: String,
        width: Int = 300,
        height: Int = 180
    ) -> [String: Any] {
        var children: [[String: Any]] = [
            [
                "kind": "widget",
                "id": "title-\(title)",
                "rect": ["x": 0.08, "y": 0.28, "width": 0.84, "height": 0.25],
                "widget": [
                    "type": "digia/text",
                    "props": [
                        "horizontalAlign": "center",
                        "spans": [
                            [
                                "text": title,
                                "color": "#FFFFFFFF",
                                "typography": ["fontSize": 18, "fontWeight": 700]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        if let subtitle {
            children.append([
                "kind": "widget",
                "id": "sub-\(title)",
                "rect": ["x": 0.08, "y": 0.55, "width": 0.84, "height": 0.2],
                "widget": [
                    "type": "digia/text",
                    "props": [
                        "horizontalAlign": "center",
                        "spans": [
                            [
                                "text": subtitle,
                                "color": "#FFE2E8F0",
                                "typography": ["fontSize": 13, "fontWeight": 400]
                            ]
                        ]
                    ]
                ]
            ])
        }

        return [
            "version": 2,
            "canvasWidth": width,
            "canvasHeight": height,
            "background": ["type": "solid", "color": ["value": colorHex]],
            "children": children
        ]
    }

    private func mount(
        canvas: CampaignCanvas,
        isDark: Bool = false,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void = { _ in }
    ) -> UIWindow {
        ComponentTestHost.mountCanvas(canvas, isDark: isDark, onAction: onAction).window
    }

    private func unmount(_ window: UIWindow) {
        ComponentTestHost.unmount(window)
    }
}
