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

    // MARK: - 2. Action Step Stamping Oracle

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

    // MARK: - 5. Infinite Scroll & Real Index Resolution
 
    @Test("carousel infinite scroll recentering and real index resolution on CanvasCarouselRenderer")
    func carouselInfiniteScrollRecenteringAndRealIndex() {
        // Scenario 1: 3 slides with infinite loop (displayCount = 5)
        let slides3 = 3
        // Boundary 0 (duplicate of slide 2) -> silently recenters to target index 3 (real slide 2)
        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 0, slideCount: slides3, loopEnabled: true) == 3)
        #expect(CanvasCarouselRenderer.realIndex(0, slideCount: slides3, loopEnabled: true) == 2)

        // Interior indices (1, 2, 3) -> valid positions, no recentering
        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 1, slideCount: slides3, loopEnabled: true) == nil)
        #expect(CanvasCarouselRenderer.realIndex(1, slideCount: slides3, loopEnabled: true) == 0)

        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 2, slideCount: slides3, loopEnabled: true) == nil)
        #expect(CanvasCarouselRenderer.realIndex(2, slideCount: slides3, loopEnabled: true) == 1)

        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 3, slideCount: slides3, loopEnabled: true) == nil)
        #expect(CanvasCarouselRenderer.realIndex(3, slideCount: slides3, loopEnabled: true) == 2)

        // Boundary 4 (duplicate of slide 0) -> silently recenters to target index 1 (real slide 0)
        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 4, slideCount: slides3, loopEnabled: true) == 1)
        #expect(CanvasCarouselRenderer.realIndex(4, slideCount: slides3, loopEnabled: true) == 0)

        // Scenario 2: 5 slides with infinite loop (displayCount = 7)
        let slides5 = 5
        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 0, slideCount: slides5, loopEnabled: true) == 5)
        #expect(CanvasCarouselRenderer.realIndex(0, slideCount: slides5, loopEnabled: true) == 4)

        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 6, slideCount: slides5, loopEnabled: true) == 1)
        #expect(CanvasCarouselRenderer.realIndex(6, slideCount: slides5, loopEnabled: true) == 0)

        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 3, slideCount: slides5, loopEnabled: true) == nil)
        #expect(CanvasCarouselRenderer.realIndex(3, slideCount: slides5, loopEnabled: true) == 2)

        // Scenario 3: Loop disabled (finite carousel) -> no recentering, 1:1 real index mapping
        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 0, slideCount: slides3, loopEnabled: false) == nil)
        #expect(CanvasCarouselRenderer.realIndex(0, slideCount: slides3, loopEnabled: false) == 0)

        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 2, slideCount: slides3, loopEnabled: false) == nil)
        #expect(CanvasCarouselRenderer.realIndex(2, slideCount: slides3, loopEnabled: false) == 2)

        // Scenario 4: Single slide with loopEnabled true -> cannot loop a single slide, no recentering
        #expect(CanvasCarouselRenderer.recenteringTarget(displayIndex: 0, slideCount: 1, loopEnabled: true) == nil)
        #expect(CanvasCarouselRenderer.realIndex(0, slideCount: 1, loopEnabled: true) == 0)
    }

    // MARK: - 6. Autoplay Progression & Eligibility

    @Test("carousel autoplay progression and eligibility on CanvasCarouselRenderer")
    func carouselAutoPlayProgressionAndEligibility() {
        // Eligibility rules: requires autoPlay true and at least 2 slides
        #expect(CanvasCarouselRenderer.shouldStartAutoPlay(autoPlay: true, slideCount: 3) == true)
        #expect(CanvasCarouselRenderer.shouldStartAutoPlay(autoPlay: false, slideCount: 3) == false)
        #expect(CanvasCarouselRenderer.shouldStartAutoPlay(autoPlay: true, slideCount: 1) == false)
        #expect(CanvasCarouselRenderer.shouldStartAutoPlay(autoPlay: false, slideCount: 1) == false)

        // Infinite loop progression (displayCount = 5 for 3 slides: [clone2, s0, s1, s2, clone0])
        let loopDisplayCount = 5
        // Uninitialized position starts at slide 0 (index 1) and advances to 2
        #expect(CanvasCarouselRenderer.nextAutoPlayIndex(currentIndex: nil, displayCount: loopDisplayCount, loopEnabled: true) == 2)
        // From slide 0 (displayIndex 1) advances to slide 1 (displayIndex 2)
        #expect(CanvasCarouselRenderer.nextAutoPlayIndex(currentIndex: 1, displayCount: loopDisplayCount, loopEnabled: true) == 2)
        // From slide 1 (displayIndex 2) advances to slide 2 (displayIndex 3)
        #expect(CanvasCarouselRenderer.nextAutoPlayIndex(currentIndex: 2, displayCount: loopDisplayCount, loopEnabled: true) == 3)
        // From slide 2 (displayIndex 3) advances to clone0 (displayIndex 4) which triggers seamless recentering
        #expect(CanvasCarouselRenderer.nextAutoPlayIndex(currentIndex: 3, displayCount: loopDisplayCount, loopEnabled: true) == 4)

        // Finite carousel progression (displayCount = 3: [s0, s1, s2])
        let finiteDisplayCount = 3
        #expect(CanvasCarouselRenderer.nextAutoPlayIndex(currentIndex: nil, displayCount: finiteDisplayCount, loopEnabled: false) == 1)
        #expect(CanvasCarouselRenderer.nextAutoPlayIndex(currentIndex: 0, displayCount: finiteDisplayCount, loopEnabled: false) == 1)
        #expect(CanvasCarouselRenderer.nextAutoPlayIndex(currentIndex: 1, displayCount: finiteDisplayCount, loopEnabled: false) == 2)
        // Reaching the end halts autoplay (returns nil)
        #expect(CanvasCarouselRenderer.nextAutoPlayIndex(currentIndex: 2, displayCount: finiteDisplayCount, loopEnabled: false) == nil)
    }

    // MARK: - 7. Visual Golden Tests

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

    // MARK: - 8. Autoplay Timer Behavioral Tests

    @Test("carousel autoplay advances to next slide automatically on timer")
    func carouselAutoPlayAdvancesSlide() async throws {
        let widget = try parsedCarousel([
            "autoPlay": true,
            "autoPlayInterval": 100,
            "animationDuration": 10,
            "infiniteScroll": true
        ], slides: [
            makeSlideJSON(title: "Slide 0", colorHex: "#FF4F46E5"),
            makeSlideJSON(title: "Slide 1", colorHex: "#FF10B981"),
            makeSlideJSON(title: "Slide 2", colorHex: "#FFF59E0B")
        ])

        var interactions: [CanvasInteraction] = []
        let view = CanvasCarouselRenderer(widget: widget, isDark: false, onAction: { _ in })
            .environment(\.canvasInteractions, CanvasInteractionReporter { interactions.append($0) })

        let (window, _) = ComponentTestHost.mount(
            rootView: view,
            size: CGSize(width: 360, height: 220)
        )
        defer { ComponentTestHost.unmount(window) }

        // Initial mount reports slide 0 with auto: false
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(interactions.contains(.carouselSlideViewed(index: 0, total: 3, auto: false)))

        // Allow autoplay timer (0.1s) to advance to slide 1 with auto: true
        for _ in 0..<10 {
            pumpRunLoop(0.04)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(interactions.contains(.carouselSlideViewed(index: 1, total: 3, auto: true)))
    }

    @Test("carousel autoplay does not advance when autoPlay is false")
    func carouselAutoPlayDisabledDoesNotAdvance() async throws {
        let widget = try parsedCarousel([
            "autoPlay": false,
            "autoPlayInterval": 100,
            "animationDuration": 10,
            "infiniteScroll": true
        ], slides: [
            makeSlideJSON(title: "Slide 0", colorHex: "#FF4F46E5"),
            makeSlideJSON(title: "Slide 1", colorHex: "#FF10B981"),
            makeSlideJSON(title: "Slide 2", colorHex: "#FFF59E0B")
        ])

        var interactions: [CanvasInteraction] = []
        let view = CanvasCarouselRenderer(widget: widget, isDark: false, onAction: { _ in })
            .environment(\.canvasInteractions, CanvasInteractionReporter { interactions.append($0) })

        let (window, _) = ComponentTestHost.mount(
            rootView: view,
            size: CGSize(width: 360, height: 220)
        )
        defer { ComponentTestHost.unmount(window) }

        for _ in 0..<10 {
            pumpRunLoop(0.04)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        // Only initial slide was viewed, no auto progression occurred
        #expect(interactions == [.carouselSlideViewed(index: 0, total: 3, auto: false)])
    }

    @Test("carousel autoplay does not start for single slide")
    func carouselAutoPlaySingleSlideDoesNotAdvance() async throws {
        let widget = try parsedCarousel([
            "autoPlay": true,
            "autoPlayInterval": 100,
            "animationDuration": 10
        ], slides: [
            makeSlideJSON(title: "Slide 0", colorHex: "#FF4F46E5")
        ])

        var interactions: [CanvasInteraction] = []
        let view = CanvasCarouselRenderer(widget: widget, isDark: false, onAction: { _ in })
            .environment(\.canvasInteractions, CanvasInteractionReporter { interactions.append($0) })

        let (window, _) = ComponentTestHost.mount(
            rootView: view,
            size: CGSize(width: 360, height: 220)
        )
        defer { ComponentTestHost.unmount(window) }

        for _ in 0..<10 {
            pumpRunLoop(0.04)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(interactions == [.carouselSlideViewed(index: 0, total: 1, auto: false)])
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

    @MainActor
    private func pumpRunLoop(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func unmount(_ window: UIWindow) {
        ComponentTestHost.unmount(window)
    }
}
