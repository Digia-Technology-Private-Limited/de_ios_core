import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas progress bar renderer", .serialized, .tags(.canvas, .component))
struct CanvasProgressBarRendererTests {

    // MARK: - 1. Progress Subsystem: Parser & Properties

    @Test("progress parser preserves percent mode with paints and corner radius")
    func progressParserPercentMode() throws {
        let pctWidget = try parsedProgress([
            "valueMode": "percent",
            "percent": "65",
            "indicator": ["type": "solid", "color": "#FF00AAFF"],
            "track": ["type": "solid", "color": "#FFE5E7EB"],
            "cornerRadius": 6,
            "animateOnAppear": ["enabled": true, "durationMs": 800]
        ])
        guard case .progress(let box, let mode, let pct, let rStart, let rCurrent, let rEnd, let indicator, let track, let radius, let anim) = pctWidget else {
            Issue.record("Expected a parsed progress widget")
            return
        }
        #expect(box == .none)
        #expect(mode == .percent)
        #expect(pct == "65")
        #expect(rStart == "0")
        #expect(rCurrent == "0")
        #expect(rEnd == "100")
        #expect(indicator == .solid(.literal("#FF00AAFF")))
        #expect(track == .solid(.literal("#FFE5E7EB")))
        #expect(radius == CampaignCanvasCornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6))
        #expect(anim.enabled == true)
        #expect(anim.durationMs == 800)
    }

    @Test("progress parser preserves range mode and clamps excessive animation duration")
    func progressParserRangeMode() throws {
        let rangeWidget = try parsedProgress([
            "valueMode": "range",
            "rangeStart": "10",
            "rangeCurrent": "45",
            "rangeEnd": "80",
            "indicator": [
                "type": "gradient",
                "gradientType": "linear",
                "angleDeg": 90,
                "stops": [
                    ["color": "#FFFF0000", "offset": 0.0],
                    ["color": "#FF00FF00", "offset": 1.0]
                ]
            ],
            "track": ["type": "solid", "color": "#FF222222"],
            "animateOnAppear": ["enabled": true, "durationMs": 99999] // Clamps to 5000 max
        ])
        guard case .progress(_, let rMode, _, let rs, let rc, let re, let rIndicator, _, _, let rAnim) = rangeWidget else {
            Issue.record("Expected a parsed progress widget")
            return
        }
        #expect(rMode == .range)
        #expect(rs == "10")
        #expect(rc == "45")
        #expect(re == "80")
        if case .gradient(let gType, let angle, _, _, _, _, _, let stops) = rIndicator {
            #expect(gType == .linear)
            #expect(angle == 90)
            #expect(stops.count == 2)
        } else {
            Issue.record("Expected gradient indicator paint")
        }
        #expect(rAnim.durationMs == 5000)
    }

    // MARK: - 2. Progress Subsystem: Oracles

    @Test("canvasProgressTarget oracle calculates normalized percent and handles edge-case clamping")
    func progressPercentOracle() {
        // Standard percent values
        #expect(canvasProgressTarget(valueMode: .percent, percent: "0", rangeStart: "0", rangeCurrent: "0", rangeEnd: "100", variables: nil) == 0.0)
        #expect(canvasProgressTarget(valueMode: .percent, percent: "45", rangeStart: "0", rangeCurrent: "0", rangeEnd: "100", variables: nil) == 0.45)
        #expect(canvasProgressTarget(valueMode: .percent, percent: "100", rangeStart: "0", rangeCurrent: "0", rangeEnd: "100", variables: nil) == 1.0)

        // Clamping bounds
        #expect(canvasProgressTarget(valueMode: .percent, percent: "-25", rangeStart: "0", rangeCurrent: "0", rangeEnd: "100", variables: nil) == 0.0)
        #expect(canvasProgressTarget(valueMode: .percent, percent: "250", rangeStart: "0", rangeCurrent: "0", rangeEnd: "100", variables: nil) == 1.0)

        // Non-numeric fallback
        #expect(canvasProgressTarget(valueMode: .percent, percent: "not_a_number", rangeStart: "0", rangeCurrent: "0", rangeEnd: "100", variables: nil) == 0.0)
    }

    @Test("canvasProgressTarget oracle calculates range mode with division-by-zero protection")
    func progressRangeOracle() {
        // Mid-range calculation: (35 - 10) / (60 - 10) = 25 / 50 = 0.5
        let mid = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "10", rangeCurrent: "35", rangeEnd: "60", variables: nil)
        #expect(abs(mid - 0.5) < 0.001)

        // Start boundary: (10 - 10) / 50 = 0
        let atStart = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "10", rangeCurrent: "10", rangeEnd: "60", variables: nil)
        #expect(atStart == 0.0)

        // End boundary: (60 - 10) / 50 = 1.0
        let atEnd = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "10", rangeCurrent: "60", rangeEnd: "60", variables: nil)
        #expect(atEnd == 1.0)

        // Clamped below start: (5 - 10) / 50 = -0.1 -> clamped to 0.0
        let below = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "10", rangeCurrent: "5", rangeEnd: "60", variables: nil)
        #expect(below == 0.0)

        // Clamped above end: (80 - 10) / 50 = 1.4 -> clamped to 1.0
        let above = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "10", rangeCurrent: "80", rangeEnd: "60", variables: nil)
        #expect(above == 1.0)

        // Division-by-zero protection: start == end
        let divZero = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "50", rangeCurrent: "50", rangeEnd: "50", variables: nil)
        #expect(divZero == 0.0)
    }

    @Test("canvasProgressTarget oracle handles inverted countdown ranges and directional clamping")
    func progressInvertedRangeOracle() {
        // Inverted range: start 100 -> end 0 (countdown from 100 to 0)
        // At 100: (100 - 100) / (0 - 100) = 0.0
        let invStart = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "100", rangeCurrent: "100", rangeEnd: "0", variables: nil)
        #expect(invStart == 0.0)

        // At 25: (25 - 100) / (0 - 100) = -75 / -100 = 0.75
        let inv25 = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "100", rangeCurrent: "25", rangeEnd: "0", variables: nil)
        #expect(abs(inv25 - 0.75) < 0.001)

        // At 0: (0 - 100) / (0 - 100) = 1.0
        let invEnd = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "100", rangeCurrent: "0", rangeEnd: "0", variables: nil)
        #expect(invEnd == 1.0)

        // Inverted range clamping: 120 (beyond start) clamps to 0.0; -20 (beyond end) clamps to 1.0
        let invBeyondStart = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "100", rangeCurrent: "120", rangeEnd: "0", variables: nil)
        #expect(invBeyondStart == 0.0)
        let invBeyondEnd = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "100", rangeCurrent: "-20", rangeEnd: "0", variables: nil)
        #expect(invBeyondEnd == 1.0)
    }

    @Test("canvasProgressTarget oracle falls back safely to zero for non-numeric range inputs")
    func progressNonNumericFallbackOracle() {
        // Non-numeric strings in range mode fall back safely to 0
        let invalidStart = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "bad_start", rangeCurrent: "bad_current", rangeEnd: "bad_end", variables: nil)
        #expect(invalidStart == 0.0)

        let invalidCurrent = canvasProgressTarget(valueMode: .range, percent: "0", rangeStart: "10", rangeCurrent: "invalid", rangeEnd: "50", variables: nil)
        #expect(invalidCurrent == 0.0)
    }

    @Test("canvasProgressTarget oracle interpolates dynamic variables in percent and range modes")
    func progressVariableInterpolationOracle() {
        let context = VariableContext(
            values: [
                "user_completion": "72",
                "game_score": "150",
                "game_target": "200"
            ],
            types: [
                "user_completion": "number",
                "game_score": "number",
                "game_target": "number"
            ]
        )

        // Interpolated percent mode
        let pct = canvasProgressTarget(
            valueMode: .percent,
            percent: "{{user_completion}}",
            rangeStart: "0",
            rangeCurrent: "0",
            rangeEnd: "100",
            variables: context
        )
        #expect(abs(pct - 0.72) < 0.001)

        // Interpolated range mode
        let range = canvasProgressTarget(
            valueMode: .range,
            percent: "0",
            rangeStart: "0",
            rangeCurrent: "{{game_score}}",
            rangeEnd: "{{game_target}}",
            variables: context
        )
        #expect(abs(range - 0.75) < 0.001)
    }

    // MARK: - 3. Visual Goldens

    @Test("progress bar renderer matches visual golden", .tags(.golden))
    func progressBarVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 120,
            "background": ["type": "solid", "color": "#FFFFFFFF"],
            "children": [
                [
                    "kind": "widget",
                    "id": "progress",
                    "rect": ["x": 0.05, "y": 0.4, "width": 0.9, "height": 0.2],
                    "widget": [
                        "type": "digia/linearProgressBar",
                        "props": [
                            "valueMode": "percent",
                            "percent": "70",
                            "indicator": ["type": "solid", "color": "#FF2563EB"],
                            "track": ["type": "solid", "color": "#FFE2E8F0"],
                            "cornerRadius": 6
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

    @Test("progress bar renderer handles 0% and 100% boundary extremes", .tags(.golden))
    func progressBarEmptyAndFullVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 120,
            "background": ["type": "solid", "color": "#FFF8FAFC"],
            "children": [
                [
                    "kind": "widget",
                    "id": "progress-empty",
                    "rect": ["x": 0.05, "y": 0.18, "width": 0.9, "height": 0.18],
                    "widget": [
                        "type": "digia/linearProgressBar",
                        "props": [
                            "valueMode": "percent",
                            "percent": "0",
                            "indicator": ["type": "solid", "color": "#FF2563EB"],
                            "track": ["type": "solid", "color": "#FFE2E8F0"],
                            "cornerRadius": 6
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "progress-full",
                    "rect": ["x": 0.05, "y": 0.62, "width": 0.9, "height": 0.18],
                    "widget": [
                        "type": "digia/linearProgressBar",
                        "props": [
                            "valueMode": "percent",
                            "percent": "100",
                            "indicator": ["type": "solid", "color": "#FF10B981"],
                            "track": ["type": "solid", "color": "#FFE2E8F0"],
                            "cornerRadius": 6
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

    private func parsedProgress(
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
                    "id": "prog1",
                    "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 0.05],
                    "widget": [
                        "type": "digia/linearProgressBar",
                        "containerProps": box,
                        "props": props
                    ]
                ]
            ]
        ])
        guard case .widget(_, _, let widget) = canvas.children.first else {
            throw DesignTokenError.invalid("Failed to parse progress widget")
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
