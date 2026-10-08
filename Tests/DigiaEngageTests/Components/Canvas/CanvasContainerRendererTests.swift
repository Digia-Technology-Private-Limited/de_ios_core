import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas container renderer", .serialized, .tags(.canvas, .component))
struct CanvasContainerRendererTests {

    // MARK: - 1. Parser & Schema Preservation

    @Test("container parser preserves solid fill and scalar corner radius")
    func parserPreservesSolidFillAndCornerRadius() throws {
        let solidWidget = try parsedContainer([
            "fill": ["type": "solid", "color": "#FF336699"],
            "cornerRadius": 14
        ])
        guard case .container(let solidFill, let solidRadius, _, _) = solidWidget else {
            Issue.record("Expected a parsed container widget")
            return
        }
        #expect(solidFill == .solid(.literal("#FF336699")))
        #expect(solidRadius == CampaignCanvasCornerRadius(topLeft: 14, topRight: 14, bottomRight: 14, bottomLeft: 14))
    }

    @Test("container parser preserves border and shadow properties")
    func parserPreservesBorderAndShadow() throws {
        let borderShadowWidget = try parsedContainer([
            "border": ["color": "#FF112233", "width": 2.5],
            "shadow": ["color": "#80000000", "blur": 12, "spread": 3, "offsetX": 1, "offsetY": 4]
        ])
        guard case .container(_, _, let solidBorder, let solidShadow) = borderShadowWidget else {
            Issue.record("Expected a parsed container widget")
            return
        }
        #expect(solidBorder == CampaignCanvasBorder(color: .literal("#FF112233"), width: 2.5))
        #expect(solidShadow == CampaignCanvasShadow(color: .literal("#80000000"), blur: 12, spread: 3, offsetX: 1, offsetY: 4))
    }

    @Test("container parser preserves linear gradient fill and 4-corner radius")
    func parserPreservesLinearGradientFill() throws {
        let linearWidget = try parsedContainer([
            "fill": [
                "type": "gradient",
                "gradientType": "linear",
                "angleDeg": 90,
                "stops": [
                    ["color": "#FFFF0000", "offset": 0.0],
                    ["color": "#FF0000FF", "offset": 1.0]
                ]
            ],
            "cornerRadius": [
                "topLeft": 6,
                "topRight": 12,
                "bottomRight": 18,
                "bottomLeft": 24
            ]
        ])
        guard case .container(let linearFill, let linearRadius, let linearBorder, let linearShadow) = linearWidget else {
            Issue.record("Expected a parsed container widget")
            return
        }
        if case .gradient(let gType, let angle, let cx, let cy, let radius, let start, let end, let stops) = linearFill {
            #expect(gType == .linear)
            #expect(angle == 90)
            #expect(cx == 0.5)
            #expect(cy == 0.5)
            #expect(radius == 0.5)
            #expect(start == 0)
            #expect(end == 360)
            #expect(stops.count == 2)
            #expect(stops[0].color == .literal("#FFFF0000"))
            #expect(stops[0].offset == 0.0)
            #expect(stops[1].color == .literal("#FF0000FF"))
            #expect(stops[1].offset == 1.0)
        } else {
            Issue.record("Expected linear gradient fill")
        }
        #expect(linearRadius == CampaignCanvasCornerRadius(topLeft: 6, topRight: 12, bottomRight: 18, bottomLeft: 24))
        #expect(linearBorder == nil)
        #expect(linearShadow == nil)
    }

    @Test("container parser preserves radial gradient fill")
    func parserPreservesRadialGradientFill() throws {
        let radialWidget = try parsedContainer([
            "fill": [
                "type": "gradient",
                "gradientType": "radial",
                "centerX": 0.3,
                "centerY": 0.7,
                "radius": 1.5,
                "stops": [
                    ["color": "#FFFFFFFF", "offset": 0.2],
                    ["color": "#FF000000", "offset": 0.8]
                ]
            ]
        ])
        guard case .container(let radialFill, _, _, _) = radialWidget else {
            Issue.record("Expected a parsed container widget")
            return
        }
        if case .gradient(let gType, _, let cx, let cy, let radius, _, _, let stops) = radialFill {
            #expect(gType == .radial)
            #expect(cx == 0.3)
            #expect(cy == 0.7)
            #expect(radius == 1.5)
            #expect(stops.count == 2)
        } else {
            Issue.record("Expected radial gradient fill")
        }
    }

    @Test("container parser preserves sweep gradient fill")
    func parserPreservesSweepGradientFill() throws {
        let sweepWidget = try parsedContainer([
            "fill": [
                "type": "gradient",
                "gradientType": "sweep",
                "startAngleDeg": 45,
                "endAngleDeg": 315,
                "stops": [
                    ["color": "#FFFF0000", "offset": 0.0],
                    ["color": "#FF00FF00", "offset": 0.5],
                    ["color": "#FF0000FF", "offset": 1.0]
                ]
            ]
        ])
        guard case .container(let sweepFill, _, _, _) = sweepWidget else {
            Issue.record("Expected a parsed container widget")
            return
        }
        if case .gradient(let gType, _, _, _, _, let start, let end, let stops) = sweepFill {
            #expect(gType == .sweep)
            #expect(start == 45)
            #expect(end == 315)
            #expect(stops.count == 3)
        } else {
            Issue.record("Expected sweep gradient fill")
        }
    }

    @Test("container parser preserves image fill and position/scale")
    func parserPreservesImageFill() throws {
        let imageWidget = try parsedContainer([
            "fill": [
                "type": "image",
                "source": ["url": "https://example.com/texture.png", "darkUrl": "https://example.com/texture-dark.png"],
                "positionX": 0.25,
                "positionY": 0.75,
                "scale": 2.5
            ]
        ])
        guard case .container(let imageFill, _, _, _) = imageWidget else {
            Issue.record("Expected a parsed container widget")
            return
        }
        if case .image(let source, let px, let py, let scale) = imageFill {
            #expect(source.url == "https://example.com/texture.png")
            #expect(source.darkUrl == "https://example.com/texture-dark.png")
            #expect(px == 0.25)
            #expect(py == 0.75)
            #expect(scale == 2.5)
        } else {
            Issue.record("Expected image fill")
        }
    }

    @Test("container parser applies safe defaults for omitted properties")
    func parserAppliesDefaults() throws {
        let emptyWidget = try parsedContainer([:])
        guard case .container(let fill, let radius, let border, let shadow) = emptyWidget else {
            Issue.record("Expected a parsed container widget")
            return
        }
        #expect(fill == .none)
        #expect(radius == CampaignCanvasCornerRadius(topLeft: 0, topRight: 0, bottomRight: 0, bottomLeft: 0))
        #expect(border == nil)
        #expect(shadow == nil)
    }

    @Test("container parser clamps gradient coordinates and radius within valid bounds")
    func containerParserClampsGradientCoordinatesAndRadius() throws {
        let clampedWidget = try parsedContainer([
            "fill": [
                "type": "gradient",
                "centerX": -0.5, // clamps to 0
                "centerY": 1.8,  // clamps to 1
                "radius": 5.0,   // clamps to 4
                "stops": [
                    ["color": "#FFFF0000", "offset": 0.0]
                ]
            ]
        ])
        guard case .container(let fill, _, _, _) = clampedWidget else {
            Issue.record("Expected a parsed container widget")
            return
        }
        if case .gradient(_, _, let cx, let cy, let radius, _, _, _) = fill {
            #expect(cx == 0.0)
            #expect(cy == 1.0)
            #expect(radius == 4.0)
        } else {
            Issue.record("Expected gradient fill")
        }
    }

    @Test("container parser sorts gradient stops by offset in ascending order")
    func containerParserSortsGradientStopsByOffset() throws {
        let sortedWidget = try parsedContainer([
            "fill": [
                "type": "gradient",
                "stops": [
                    ["color": "#FF0000FF", "offset": 0.9],
                    ["color": "#FFFF0000", "offset": 0.1],
                    ["color": "#FF00FF00", "offset": 0.5]
                ]
            ]
        ])
        guard case .container(let fill, _, _, _) = sortedWidget else {
            Issue.record("Expected a parsed container widget")
            return
        }
        if case .gradient(_, _, _, _, _, _, _, let stops) = fill {
            #expect(stops.count == 3)
            #expect(stops[0].offset == 0.1)
            #expect(stops[1].offset == 0.5)
            #expect(stops[2].offset == 0.9)
        } else {
            Issue.record("Expected gradient fill")
        }
    }

    @Test("container parser clamps shadow blur and spread to safe ranges")
    func containerParserClampsShadowBlurAndSpread() throws {
        let shadowWidget = try parsedContainer([
            "shadow": [
                "color": "#80000000",
                "blur": 350,   // clamps to 200
                "spread": -20  // clamps min 0
            ]
        ])
        guard case .container(_, _, _, let shadow) = shadowWidget else {
            Issue.record("Expected a parsed container widget")
            return
        }
        #expect(shadow?.blur == 200)
        #expect(shadow?.spread == 0)
    }

    // MARK: - 2. Oracle: CampaignCanvasRoundedShape Math & Path

    @Test("rounded shape uniform corners generates standard continuous rounded rect")
    func roundedShapeUniformCorners() {
        let shape = CampaignCanvasRoundedShape(radius: CampaignCanvasCornerRadius(topLeft: 12, topRight: 12, bottomRight: 12, bottomLeft: 12))
        let rect = CGRect(x: 0, y: 0, width: 120, height: 80)
        let path = shape.path(in: rect)

        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        #expect(abs(bounds.origin.x - rect.origin.x) < 0.001)
        #expect(abs(bounds.origin.y - rect.origin.y) < 0.001)
        #expect(abs(bounds.width - rect.width) < 0.001)
        #expect(abs(bounds.height - rect.height) < 0.001)
    }

    @Test("rounded shape non-uniform corners builds tangent arcs accurately")
    func roundedShapeNonUniformCorners() {
        let shape = CampaignCanvasRoundedShape(radius: CampaignCanvasCornerRadius(topLeft: 4, topRight: 10, bottomRight: 16, bottomLeft: 22))
        let rect = CGRect(x: 0, y: 0, width: 200, height: 150)
        let path = shape.path(in: rect)

        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        #expect(abs(bounds.width - rect.width) < 0.001)
        #expect(abs(bounds.height - rect.height) < 0.001)
    }

    @Test("rounded shape factor scaling proportionally reduces oversized corner radii")
    func roundedShapeFactorScaling() {
        // Width = 100, topSum = 80 + 80 = 160 > 100. Factor = 100 / 160 = 0.625.
        // Scaled tl = 50, tr = 50, br = 0, bl = 0.
        let shape = CampaignCanvasRoundedShape(radius: CampaignCanvasCornerRadius(topLeft: 80, topRight: 80, bottomRight: 0, bottomLeft: 0))
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = shape.path(in: rect)

        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        #expect(abs(bounds.width - rect.width) < 0.001)
        #expect(abs(bounds.height - rect.height) < 0.001)

        // Height constraint: height = 60, rightSum = 50 + 50 = 100 > 60. Factor = 60 / 100 = 0.6.
        let heightShape = CampaignCanvasRoundedShape(radius: CampaignCanvasCornerRadius(topLeft: 0, topRight: 50, bottomRight: 50, bottomLeft: 0))
        let heightRect = CGRect(x: 0, y: 0, width: 200, height: 60)
        let heightPath = heightShape.path(in: heightRect)
        #expect(!heightPath.isEmpty)
    }

    @Test("rounded shape insetting reduces boundaries and corners correctly")
    func roundedShapeInsetting() {
        let original = CampaignCanvasRoundedShape(radius: CampaignCanvasCornerRadius(topLeft: 16, topRight: 16, bottomRight: 16, bottomLeft: 16))
        let inset = original.inset(by: 4)
        #expect(inset.insetAmount == 4)

        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = inset.path(in: rect)
        #expect(!path.isEmpty)

        // Insetting by 4 on all sides shrinks the rect to (4, 4, 92, 92)
        let bounds = path.boundingRect
        #expect(abs(bounds.origin.x - 4) < 0.001)
        #expect(abs(bounds.origin.y - 4) < 0.001)
        #expect(abs(bounds.width - 92) < 0.001)
        #expect(abs(bounds.height - 92) < 0.001)

        // Degenerate insetting: inset amount >= min(width, height) / 2 collapses rect
        let overInset = original.inset(by: 60)
        let overPath = overInset.path(in: rect)
        #expect(overPath.isEmpty)
    }

    @Test("rounded shape degenerate rects return empty path")
    func roundedShapeDegenerateRects() {
        let shape = CampaignCanvasRoundedShape(radius: CampaignCanvasCornerRadius(topLeft: 8, topRight: 8, bottomRight: 8, bottomLeft: 8))

        #expect(shape.path(in: CGRect(x: 0, y: 0, width: 0, height: 100)).isEmpty)
        #expect(shape.path(in: CGRect(x: 0, y: 0, width: 100, height: 0)).isEmpty)
        #expect(shape.path(in: .zero).isEmpty)
    }

    // MARK: - 3. Oracle: Box Surface Visibility & Shadow Calculations

    @Test("hasVisibleSurface accurately differentiates opaque surfaces from transparent cutouts")
    func boxSurfaceVisibilityOracle() {
        // 1. None fill and no border -> not visible
        let emptyBox = CampaignCanvasBox(fill: .none, border: nil)
        #expect(emptyBox.hasVisibleSurface(isDark: false) == false)
        #expect(emptyBox.hasVisibleSurface(isDark: true) == false)

        // 2. Solid fill with alpha > 0 -> visible
        let solidBox = CampaignCanvasBox(fill: .solid(.literal("#FF112233")), border: nil)
        #expect(solidBox.hasVisibleSurface(isDark: false) == true)

        // 3. Solid fill with alpha == 0 -> not visible
        let transparentSolidBox = CampaignCanvasBox(fill: .solid(.literal("#00000000")), border: nil)
        #expect(transparentSolidBox.hasVisibleSurface(isDark: false) == false)

        // 4. None fill with visible border -> visible
        let borderedBox = CampaignCanvasBox(fill: .none, border: CampaignCanvasBorder(color: .literal("#FF000000"), width: 2))
        #expect(borderedBox.hasVisibleSurface(isDark: false) == true)

        // 5. None fill with zero-width border -> not visible
        let zeroBorderBox = CampaignCanvasBox(fill: .none, border: CampaignCanvasBorder(color: .literal("#FF000000"), width: 0))
        #expect(zeroBorderBox.hasVisibleSurface(isDark: false) == false)

        // 6. None fill with transparent border -> not visible
        let transBorderBox = CampaignCanvasBox(fill: .none, border: CampaignCanvasBorder(color: .literal("#00000000"), width: 2))
        #expect(transBorderBox.hasVisibleSurface(isDark: false) == false)

        // 7. Gradient fill -> visible
        let gradientBox = CampaignCanvasBox(
            fill: .gradient(type: .linear, angleDegrees: 0, centerX: 0.5, centerY: 0.5, radius: 0.5, startAngleDegrees: 0, endAngleDegrees: 360, stops: []),
            border: nil
        )
        #expect(gradientBox.hasVisibleSurface(isDark: false) == true)

        // 8. Image fill -> visible
        let imageBox = CampaignCanvasBox(
            fill: .image(source: CampaignCanvasMediaSource(url: "https://example.com/bg.png", darkUrl: nil, placeholder: nil), positionX: 0.5, positionY: 0.5, scale: 1),
            border: nil
        )
        #expect(imageBox.hasVisibleSurface(isDark: false) == true)
    }

    // MARK: - Helpers

    private func parsedContainer(_ props: [String: Any]) throws -> CampaignCanvasWidget {
        let canvasJSON: [String: Any] = [
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 420,
            "children": [
                [
                    "id": "container_test",
                    "kind": "widget",
                    "rect": ["x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8],
                    "widget": [
                        "type": "digia/canvasContainer",
                        "props": props
                    ]
                ]
            ]
        ]
        let canvas = try CampaignCanvasParser().parse(canvasJSON)
        guard let first = canvas.children.first,
              case .widget(_, _, let widget) = first else {
            throw DesignTokenError.invalid("Failed to parse container widget")
        }
        return widget
    }

    // MARK: - 10. Visual Golden

    @Test("container renderer matches visual golden", .tags(.golden))
    func containerRendererVisualGolden() throws {
        let container = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 180,
            "background": ["type": "solid", "color": "#FFF1F5F9"],
            "children": [
                [
                    "kind": "widget",
                    "id": "card",
                    "rect": ["x": 0.08, "y": 0.15, "width": 0.84, "height": 0.7],
                    "widget": [
                        "type": "digia/canvasContainer",
                        "props": [
                            "fill": ["type": "solid", "color": "#FFFFFFFF"],
                            "cornerRadius": 16,
                            "border": [
                                "width": 2,
                                "color": "#FFE2E8F0"
                            ],
                            "shadow": [
                                "color": "#1A000000",
                                "blur": 12,
                                "spread": 0,
                                "offsetX": 0,
                                "offsetY": 6
                            ]
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "inner-text",
                    "rect": ["x": 0.12, "y": 0.35, "width": 0.76, "height": 0.3],
                    "widget": [
                        "type": "digia/text",
                        "props": [
                            "horizontalAlign": "center",
                            "textAlign": "center",
                            "verticalAlign": "center",
                            "spans": [
                                [
                                    "text": "Card Container",
                                    "typography": ["fontSize": 18, "fontWeight": 700],
                                    "color": "#FF0F172A"
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        let window = mount(canvas: container)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("container renderer handles linear gradient fills with multiple stops and borders", .tags(.golden))
    func containerRendererLinearGradientVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 140,
            "background": ["type": "solid", "color": "#FF0F172A"],
            "children": [
                [
                    "kind": "widget",
                    "id": "gradient-box",
                    "rect": ["x": 0.05, "y": 0.1, "width": 0.9, "height": 0.8],
                    "widget": [
                        "type": "digia/canvasContainer",
                        "props": [
                            "fill": [
                                "type": "gradient",
                                "gradientType": "linear",
                                "angleDeg": 45,
                                "stops": [
                                    ["color": "#FF8B5CF6", "offset": 0.0],
                                    ["color": "#FF3B82F6", "offset": 0.5],
                                    ["color": "#FF06B6D4", "offset": 1.0]
                                ]
                            ],
                            "cornerRadius": 16,
                            "border": [
                                "width": 1.5,
                                "color": "#66FFFFFF"
                            ],
                            "shadow": [
                                "color": "#4D3B82F6",
                                "blur": 16,
                                "spread": 0,
                                "offsetX": 0,
                                "offsetY": 6
                            ]
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "gradient-label",
                    "rect": ["x": 0.1, "y": 0.35, "width": 0.8, "height": 0.3],
                    "widget": [
                        "type": "digia/text",
                        "props": [
                            "horizontalAlign": "center",
                            "textAlign": "center",
                            "verticalAlign": "center",
                            "spans": [
                                [
                                    "text": "Gradient Card Container",
                                    "typography": ["fontSize": 17, "fontWeight": 700],
                                    "color": "#FFFFFFFF"
                                ]
                            ]
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

    @Test("container renderer handles asymmetric corner radiuses for sheet style layout", .tags(.golden))
    func containerRendererAsymmetricCornersVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 140,
            "background": ["type": "solid", "color": "#FFF1F5F9"],
            "children": [
                [
                    "kind": "widget",
                    "id": "sheet-box",
                    "rect": ["x": 0.05, "y": 0.1, "width": 0.9, "height": 0.8],
                    "widget": [
                        "type": "digia/canvasContainer",
                        "props": [
                            "fill": ["type": "solid", "color": "#FFFFFFFF"],
                            "cornerRadius": [
                                "topLeft": 32,
                                "topRight": 32,
                                "bottomRight": 0,
                                "bottomLeft": 0
                            ],
                            "border": [
                                "width": 2,
                                "color": "#FFCBD5E1"
                            ],
                            "shadow": [
                                "color": "#1A000000",
                                "blur": 12,
                                "spread": 0,
                                "offsetX": 0,
                                "offsetY": 4
                            ]
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "sheet-label",
                    "rect": ["x": 0.1, "y": 0.35, "width": 0.8, "height": 0.3],
                    "widget": [
                        "type": "digia/text",
                        "props": [
                            "horizontalAlign": "center",
                            "textAlign": "center",
                            "verticalAlign": "center",
                            "spans": [
                                [
                                    "text": "Top-Sheet Container",
                                    "typography": ["fontSize": 17, "fontWeight": 700],
                                    "color": "#FF0F172A"
                                ]
                            ]
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
