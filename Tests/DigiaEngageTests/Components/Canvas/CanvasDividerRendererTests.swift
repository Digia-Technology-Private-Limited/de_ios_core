import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas divider renderer", .serialized, .tags(.canvas, .component))
struct CanvasDividerRendererTests {

    // MARK: - 1. Divider Subsystem: Parser & Properties

    @Test("divider parser preserves horizontal solid configuration with stroke cap butt and insets")
    func dividerParserHorizontalSolid() throws {
        let hWidget = try parsedDivider([
            "type": "horizontal",
            "style": "solid",
            "strokeCap": "butt",
            "inset": 12,
            "color": "#FF224466"
        ])
        guard case .divider(let box, let axis, let pattern, let strokeCap, let inset, let dashPattern, let color) = hWidget else {
            Issue.record("Expected a parsed divider widget")
            return
        }
        #expect(box == .none)
        #expect(axis == .horizontal)
        #expect(pattern == .solid)
        #expect(strokeCap == .butt)
        #expect(inset == 12)
        #expect(dashPattern == [8, 4])
        #expect(color == .literal("#FF224466"))
    }

    @Test("divider parser preserves vertical dashed configuration and clamps negative insets")
    func dividerParserVerticalDashed() throws {
        let vWidget = try parsedDivider([
            "type": "vertical",
            "style": "dashed",
            "strokeCap": "round",
            "inset": -5, // Negative inset clamped to 0
            "dashPattern": [8, 4],
            "color": "#FFAABBCC"
        ])
        guard case .divider(_, let vAxis, let vPattern, let vStrokeCap, let vInset, let vDashPattern, let vColor) = vWidget else {
            Issue.record("Expected a parsed divider widget")
            return
        }
        #expect(vAxis == .vertical)
        #expect(vPattern == .dashed)
        #expect(vStrokeCap == .round)
        #expect(vInset == 0) // clamped
        #expect(vDashPattern == [8, 4])
        #expect(vColor == .literal("#FFAABBCC"))
    }

    @Test("divider parser preserves dotted configuration with square cap and fallback color")
    func dividerParserDottedSquareCap() throws {
        let dottedWidget = try parsedDivider([
            "type": "horizontal",
            "style": "dotted",
            "strokeCap": "square"
        ])
        guard case .divider(_, _, let dotPattern, let dotCap, _, _, let dotColor) = dottedWidget else {
            Issue.record("Expected a parsed divider widget")
            return
        }
        #expect(dotPattern == .dotted)
        #expect(dotCap == .square)
        #expect(dotColor == .literal("#FFE0E0E0")) // fallback
    }

    // MARK: - 2. Divider Subsystem: Oracles

    @Test("canvasDividerDashPattern for solid pattern returns empty dash lengths")
    func dividerDashPatternSolid() {
        #expect(canvasDividerDashPattern(pattern: .solid, thickness: 2, dashPattern: [10, 5]).isEmpty)
        #expect(canvasDividerDashPattern(pattern: .solid, thickness: 10, dashPattern: []).isEmpty)
    }

    @Test("canvasDividerDashPattern for dotted pattern produces zero-length dash with maximum of thickness and gap")
    func dividerDashPatternDotted() {
        // Case A: empty authored dash pattern falls back to gap 4
        #expect(canvasDividerDashPattern(pattern: .dotted, thickness: 2, dashPattern: []) == [0, 4])
        // Case B: thickness larger than gap
        #expect(canvasDividerDashPattern(pattern: .dotted, thickness: 8, dashPattern: [0, 4]) == [0, 8])
        // Case C: authored gap larger than thickness
        #expect(canvasDividerDashPattern(pattern: .dotted, thickness: 2, dashPattern: [0, 10]) == [0, 10])
    }

    @Test("canvasDividerDashPattern for dashed pattern returns authored pattern directly")
    func dividerDashPatternDashed() {
        #expect(canvasDividerDashPattern(pattern: .dashed, thickness: 3, dashPattern: [6, 3]) == [6, 3])
        #expect(canvasDividerDashPattern(pattern: .dashed, thickness: 1, dashPattern: [12, 4, 2, 4]) == [12, 4, 2, 4])
    }


    // MARK: - 3. Visual Goldens

    @Test("divider renderer matches visual golden", .tags(.golden))
    func dividerVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 120,
            "background": ["type": "solid", "color": "#FFFFFFFF"],
            "children": [
                [
                    "kind": "widget",
                    "id": "divider",
                    "rect": ["x": 0.05, "y": 0.45, "width": 0.9, "height": 0.1],
                    "widget": [
                        "type": "digia/styledHorizontalDivider",
                        "props": [
                            "type": "horizontal",
                            "style": "dashed",
                            "strokeCap": "round",
                            "inset": 0,
                            "dashPattern": [8, 4],
                            "color": "#FF64748B"
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

    @Test("divider renderer handles dotted patterns and vertical orientation", .tags(.golden))
    func dividerPatternsAndVerticalAxisVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 120,
            "background": ["type": "solid", "color": "#FFFFFFFF"],
            "children": [
                [
                    "kind": "widget",
                    "id": "dotted-divider",
                    "rect": ["x": 0.05, "y": 0.2, "width": 0.9, "height": 0.05],
                    "widget": [
                        "type": "digia/styledHorizontalDivider",
                        "props": [
                            "type": "horizontal",
                            "style": "dotted",
                            "strokeCap": "round",
                            "inset": 0,
                            "dashPattern": [2, 6],
                            "color": "#FF6366F1"
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "vertical-divider",
                    "rect": ["x": 0.5, "y": 0.45, "width": 0.02, "height": 0.45],
                    "widget": [
                        "type": "digia/styledHorizontalDivider",
                        "props": [
                            "type": "vertical",
                            "style": "solid",
                            "strokeCap": "square",
                            "color": "#FF94A3B8"
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

    // MARK: - Test Helpers

    private func parsedDivider(
        _ props: [String: Any],
        box: [String: Any] = [:]
    ) throws -> CampaignCanvasWidget {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 200,
            "children": [
                [
                    "kind": "widget",
                    "id": "div1",
                    "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 0.05],
                    "widget": [
                        "type": "digia/styledHorizontalDivider",
                        "containerProps": box,
                        "props": props
                    ]
                ]
            ]
        ])
        guard case .widget(_, _, let widget) = canvas.children.first else {
            throw DesignTokenError.invalid("Failed to parse divider widget")
        }
        return widget
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
