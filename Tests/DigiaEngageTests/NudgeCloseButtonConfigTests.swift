import SwiftUI
import Testing
@testable import DigiaEngage

@Suite("Nudge close button configuration", .tags(.nudge, .contract))
struct NudgeCloseButtonConfigTests {
    private func config(container: [String: Any] = [:], spacing: Any = 24) throws -> NudgeConfig {
        try #require(NudgeConfig.fromJson([
            "container": container,
            "layout": [
                "type": "digia/column",
                "props": ["spacing": spacing],
                "children": [],
            ],
        ]))
    }

    @Test("canvas outside close uses margin and ignores the removed gap key")
    func canvasOutsideMargin() throws {
        let placement = try #require(NudgeCloseButtonPlacement.fromCloseJson([
            "placement": NSNull(),
            "outsidePlacement": [
                "horizontal": "left",
                "vertical": "bottom",
                "margin": ["top": 3, "right": 5, "bottom": 7, "left": 11],
                "gap": 99,
            ],
        ]))
        let legacyGapOnly = try #require(NudgeCloseButtonPlacement.fromCloseJson([
            "placement": NSNull(),
            "outsidePlacement": ["gap": 99],
        ]))
        let uniformMargin = try #require(NudgeCloseButtonPlacement.fromCloseJson([
            "placement": NSNull(),
            "outsidePlacement": ["margin": 9],
        ]))

        #expect(placement.horizontal == .left)
        #expect(placement.vertical == .bottom)
        #expect(placement.margin == .init(top: 3, right: 5, bottom: 7, left: 11))
        #expect(legacyGapOnly.margin == .init())
        #expect(uniformMargin.margin == .init(top: 9, right: 9, bottom: 9, left: 9))

        let layout = try #require(placement.layout(
            diameter: 20,
            container: CGRect(x: 20, y: 60, width: 160, height: 100),
            safe: CGRect(x: 0, y: 0, width: 200, height: 200),
            isBottomSheet: false))
        #expect(layout.circle.minX == 20)
        #expect(layout.circle.minY == 160)
        #expect(layout.touch == layout.circle)

        let insideFallback = try #require(NudgeCloseButtonPlacement(
            horizontal: .left,
            vertical: .top,
            margin: .init(top: 40, right: 40, bottom: 40, left: 40)
        ).layout(
            diameter: 20,
            container: CGRect(x: 20, y: 10, width: 160, height: 150),
            safe: CGRect(x: 0, y: 0, width: 200, height: 200),
            isBottomSheet: false
        ))
        #expect(insideFallback.circle == CGRect(x: 20, y: 10, width: 20, height: 20))
    }

    @Test("missing close button config preserves the existing appearance")
    func defaults() throws {
        let surface = try config().surface
        let close = surface.closeButton
        #expect(close == .defaults)
        #expect(close.diameter == 26)
        #expect(surface.bottomSafeAreaMode == .insetContent)
    }

    @Test("bottom safe-area mode accepts known values and safely defaults unknown values")
    func bottomSafeAreaMode() throws {
        #expect(try config(container: ["bottomSafeAreaMode": "insetSurface"]).surface.bottomSafeAreaMode == .insetSurface)
        #expect(try config(container: ["bottomSafeAreaMode": "none"]).surface.bottomSafeAreaMode == .none)
        #expect(try config(container: ["bottomSafeAreaMode": "invalid"]).surface.bottomSafeAreaMode == .insetContent)
    }

    @Test("custom close button config clamps negatives and accepts zero")
    func customValues() throws {
        let close = try config(container: [
            "closeButton": [
                "marginTop": -8,
                "marginRight": 0,
                "backgroundColor": "#80112233",
                "iconColor": "#AABBCC",
                "iconSize": 0,
            ]
        ]).surface.closeButton

        #expect(close.marginTop == 0)
        #expect(close.marginRight == 0)
        #expect(close.iconSize == 0)
        #expect(close.diameter == 10)
        #expect(close.backgroundColor == Color(hex: "#80112233"))
        #expect(close.iconColor == Color(hex: "#AABBCC"))
    }

    @Test("malformed close button config falls back safely")
    func malformedValues() throws {
        let close = try config(container: [
            "closeButton": [
                "marginTop": "invalid",
                "backgroundColor": "transparent",
                "iconColor": "#GGGGGG",
                "iconSize": "invalid",
            ]
        ]).surface.closeButton

        #expect(close == .defaults)
    }

    @Test("legacy column spacing is ignored")
    func ignoresSpacing() throws {
        let legacy = try config(spacing: 42)
        let zeroSpacing = try config(spacing: 0)
        #expect(legacy.layout == zeroSpacing.layout)
    }

    // MARK: - Table-Driven Close Button Placement Math

    struct PlacementFromJsonCase: CustomTestStringConvertible, @unchecked Sendable {
        let input: [String: Any]?
        let expectedRect: CGRect?
        let testDescription: String
    }

    @Test(
        "NudgeCloseButtonPlacement.fromJson parses valid rect and rejects malformed inputs",
        arguments: [
            PlacementFromJsonCase(
                input: ["x": 10, "y": 20, "width": 30, "height": 40],
                expectedRect: CGRect(x: 10, y: 20, width: 30, height: 40),
                testDescription: "valid numeric coordinates and dimensions"
            ),
            PlacementFromJsonCase(
                input: nil,
                expectedRect: nil,
                testDescription: "nil dictionary"
            ),
            PlacementFromJsonCase(
                input: ["x": 10, "y": 20, "width": 30],
                expectedRect: nil,
                testDescription: "missing dimension key (height)"
            ),
            PlacementFromJsonCase(
                input: ["x": 10, "y": 20, "width": 0, "height": 40],
                expectedRect: nil,
                testDescription: "zero width"
            ),
            PlacementFromJsonCase(
                input: ["x": 10, "y": 20, "width": 30, "height": -5],
                expectedRect: nil,
                testDescription: "negative height"
            ),
            PlacementFromJsonCase(
                input: ["x": true, "y": 20, "width": 30, "height": 40],
                expectedRect: nil,
                testDescription: "boolean x value"
            ),
            PlacementFromJsonCase(
                input: ["x": "10", "y": 20, "width": 30, "height": 40],
                expectedRect: nil,
                testDescription: "string x value"
            ),
            PlacementFromJsonCase(
                input: ["x": Double.nan, "y": 20, "width": 30, "height": 40],
                expectedRect: nil,
                testDescription: "NaN coordinate"
            )
        ]
    )
    func testPlacementFromJson(testCase: PlacementFromJsonCase) {
        let parsed = NudgeCloseButtonPlacement.fromJson(testCase.input)
        #expect(parsed?.rect == testCase.expectedRect)
    }

    struct ForCanvasCase: CustomTestStringConvertible, Sendable {
        let sourceRect: CGRect?
        let sourceSize: CGSize
        let targetSize: CGSize
        let expectedRect: CGRect?
        let testDescription: String
    }

    @Test(
        "NudgeCloseButtonPlacement.forCanvas transforms coordinates proportionally across canvases",
        arguments: [
            ForCanvasCase(
                sourceRect: nil,
                sourceSize: CGSize(width: 100, height: 100),
                targetSize: CGSize(width: 200, height: 200),
                expectedRect: nil,
                testDescription: "nil rect returns self unchanged"
            ),
            ForCanvasCase(
                sourceRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                sourceSize: .zero,
                targetSize: CGSize(width: 200, height: 200),
                expectedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                testDescription: "zero source size returns unchanged"
            ),
            ForCanvasCase(
                sourceRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                sourceSize: CGSize(width: 100, height: 100),
                targetSize: .zero,
                expectedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                testDescription: "zero target size returns unchanged"
            ),
            ForCanvasCase(
                sourceRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                sourceSize: CGSize(width: 100, height: 100),
                targetSize: CGSize(width: 200, height: 200),
                expectedRect: CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1),
                testDescription: "leading-pinned rect transforms with correct end-gap handling"
            ),
            ForCanvasCase(
                sourceRect: CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2),
                sourceSize: CGSize(width: 100, height: 100),
                targetSize: CGSize(width: 200, height: 200),
                expectedRect: CGRect(x: 0.85, y: 0.85, width: 0.1, height: 0.1),
                testDescription: "trailing-pinned rect anchors against opposite edge"
            )
        ]
    )
    func testForCanvasScaling(testCase: ForCanvasCase) {
        let placement = NudgeCloseButtonPlacement(
            horizontal: .left,
            vertical: .top,
            margin: .init(),
            rect: testCase.sourceRect
        )
        let transformed = placement.forCanvas(source: testCase.sourceSize, target: testCase.targetSize)
        if let expected = testCase.expectedRect {
            guard let actual = transformed.rect else {
                Issue.record("Expected rect \(expected) but was nil")
                return
            }
            #expect(abs(actual.minX - expected.minX) < 0.001)
            #expect(abs(actual.minY - expected.minY) < 0.001)
            #expect(abs(actual.width - expected.width) < 0.001)
            #expect(abs(actual.height - expected.height) < 0.001)
        } else {
            #expect(transformed.rect == nil)
        }
    }

    struct MarginFromJsonCase: CustomTestStringConvertible, @unchecked Sendable {
        let input: Any?
        let expected: NudgeCloseButtonPlacement.Margin
        let testDescription: String
    }

    @Test(
        "NudgeCloseButtonPlacement.Margin.fromJson parses scalar, dictionary, and safe fallbacks",
        arguments: [
            MarginFromJsonCase(
                input: 16,
                expected: NudgeCloseButtonPlacement.Margin(top: 16, right: 16, bottom: 16, left: 16),
                testDescription: "single numeric scalar applied to all sides"
            ),
            MarginFromJsonCase(
                input: ["top": 4, "right": 8, "bottom": 12, "left": 16],
                expected: NudgeCloseButtonPlacement.Margin(top: 4, right: 8, bottom: 12, left: 16),
                testDescription: "dictionary with individual side margins"
            ),
            MarginFromJsonCase(
                input: true,
                expected: NudgeCloseButtonPlacement.Margin(),
                testDescription: "boolean input falls back to zero"
            ),
            MarginFromJsonCase(
                input: -10,
                expected: NudgeCloseButtonPlacement.Margin(),
                testDescription: "negative scalar falls back to zero"
            ),
            MarginFromJsonCase(
                input: "invalid",
                expected: NudgeCloseButtonPlacement.Margin(),
                testDescription: "non-numeric string falls back to zero"
            )
        ]
    )
    func testMarginFromJson(testCase: MarginFromJsonCase) {
        #expect(NudgeCloseButtonPlacement.Margin.fromJson(testCase.input) == testCase.expected)
    }
}
