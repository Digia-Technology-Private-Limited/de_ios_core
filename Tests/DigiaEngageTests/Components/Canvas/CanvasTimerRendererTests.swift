import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas timer renderer", .serialized, .tags(.canvas, .component))
struct CanvasTimerRendererTests {

    // MARK: - 1. Timer Subsystem: Parser & Layout

    @Test("timer parser preserves preset, unit visibility, labels, custom layout, and shared/override styles")
    func timerParserPreservesAllProperties() throws {
        let timerWidget = try parsedTimer([
            "preset": "unitBoxes",
            "separator": " : ",
            "units": [
                "days": "autoHide",
                "hours": true,
                "minutes": true,
                "seconds": false
            ],
            "labels": [
                "days": "D",
                "hours": "H",
                "minutes": "M"
            ],
            "digitColor": "#FFFFFFFF",
            "labelColor": "#FFCCCCCC",
            "boxFill": ["type": "solid", "color": "#FF1E293B"],
            "cornerRadius": 8,
            "unitOverrides": [
                "days": [
                    "digitColor": "#FFFFD700"
                ]
            ],
            "alignment": "left",
            "separatorEnabled": true,
            "separatorColor": "#FF94A3B8",
            "unitSizes": [
                "hours": ["width": 56, "height": 64]
            ],
            "unitGaps": [
                "hours": 6
            ]
        ])
        guard let timerWidget, case .timer(let box, let preset, let sep, let units, let labels, _, _, let sharedStyle, let overrides, let layout) = timerWidget else {
            Issue.record("Expected a parsed timer widget")
            return
        }
        #expect(box == .none)
        #expect(preset == "unitBoxes")
        #expect(sep == " : ")
        #expect(units[.days] == .autoHide)
        #expect(units[.hours] == .show)
        #expect(units[.minutes] == .show)
        #expect(units[.seconds] == .hide)
        #expect(labels[.days] == "D")
        #expect(labels[.hours] == "H")
        #expect(labels[.minutes] == "M")

        #expect(sharedStyle.digitColor == .literal("#FFFFFFFF"))
        #expect(sharedStyle.labelColor == .literal("#FFCCCCCC"))
        #expect(sharedStyle.boxFill == .solid(.literal("#FF1E293B")))
        #expect(sharedStyle.cornerRadius == CampaignCanvasCornerRadius(topLeft: 8, topRight: 8, bottomRight: 8, bottomLeft: 8))

        // Check override inherits shared fallback
        let daysOverride = overrides[.days]
        #expect(daysOverride?.digitColor == .literal("#FFFFD700"))
        #expect(daysOverride?.labelColor == .literal("#FFCCCCCC")) // inherited

        // Layout customization checks
        #expect(layout.alignment == .left)
        #expect(layout.separatorEnabled == true)
        #expect(layout.separatorColor == .literal("#FF94A3B8"))
        #expect(layout.sizes[.hours] == CGSize(width: 56, height: 64))
        #expect(layout.gaps[.hours] == 6)
        #expect(layout.isCustomized == true)
    }

    @Test("timer parser rejects invalid presets and all-hidden configurations")
    func timerParserRejections() throws {
        // Unknown preset returns nil
        let invalidPreset = try parsedTimer([
            "preset": "circularGauge",
            "units": ["seconds": true]
        ])
        #expect(invalidPreset == nil)

        // All units set to false returns nil (fail-safe drops empty timer)
        let allHidden = try parsedTimer([
            "preset": "text",
            "units": [
                "days": false,
                "hours": false,
                "minutes": false,
                "seconds": false
            ]
        ])
        #expect(allHidden == nil)
    }

    // MARK: - 2. Timer Subsystem: Oracles

    @Test("timerUnitValues oracle breaks down remaining seconds across days, hours, minutes, and seconds")
    func timerUnitValuesBreakdownOracle() {
        let allUnits: [CampaignTimerUnit: CampaignTimerUnitVisibility] = [
            .days: .show,
            .hours: .show,
            .minutes: .show,
            .seconds: .show
        ]

        // 90061s = 1 day (86400) + 1 hour (3600) + 1 minute (60) + 1 second (1)
        let breakdown1 = timerUnitValues(remainingSeconds: 90061, visibility: allUnits)
        #expect(breakdown1.count == 4)
        #expect(breakdown1[0] == (.days, 1))
        #expect(breakdown1[1] == (.hours, 1))
        #expect(breakdown1[2] == (.minutes, 1))
        #expect(breakdown1[3] == (.seconds, 1))

        // 3665s = 0 days, 1 hour, 1 minute, 5 seconds
        let breakdown2 = timerUnitValues(remainingSeconds: 3665, visibility: allUnits)
        #expect(breakdown2[0] == (.days, 0))
        #expect(breakdown2[1] == (.hours, 1))
        #expect(breakdown2[2] == (.minutes, 1))
        #expect(breakdown2[3] == (.seconds, 5))
    }

    @Test("timerUnitValues oracle handles autoHide zero-suppression and fallback preservation")
    func timerUnitValuesAutoHideOracle() {
        let autoHideDays: [CampaignTimerUnit: CampaignTimerUnitVisibility] = [
            .days: .autoHide,
            .hours: .show,
            .minutes: .show,
            .seconds: .show
        ]

        // When days == 0 and autoHide, days is suppressed from result
        let resNoDays = timerUnitValues(remainingSeconds: 3665, visibility: autoHideDays)
        #expect(!resNoDays.contains { $0.0 == .days })
        #expect(resNoDays.count == 3)
        #expect(resNoDays[0] == (.hours, 1))

        // When days > 0 and autoHide, days is preserved
        let resWithDays = timerUnitValues(remainingSeconds: 90000, visibility: autoHideDays)
        #expect(resWithDays.first?.0 == .days)
        #expect(resWithDays.first?.1 == 1)

        // When all units are autoHide and remainingSeconds == 0, fallback preserves smallest unit
        let allAutoHide: [CampaignTimerUnit: CampaignTimerUnitVisibility] = [
            .days: .autoHide,
            .hours: .autoHide,
            .minutes: .autoHide,
            .seconds: .autoHide
        ]
        let zeroFallback = timerUnitValues(remainingSeconds: 0, visibility: allAutoHide)
        #expect(zeroFallback.count == 1)
        #expect(zeroFallback[0] == (.seconds, 0))
    }

    @Test("timerUnitValues oracle clamps negative time and respects subset of configured units")
    func timerUnitValuesEdgeCasesOracle() {
        // Negative seconds safely clamped to 0
        let negativeRes = timerUnitValues(
            remainingSeconds: -120,
            visibility: [.days: .hide, .hours: .hide, .minutes: .show, .seconds: .show]
        )
        #expect(negativeRes.count == 2)
        #expect(negativeRes[0] == (.minutes, 0))
        #expect(negativeRes[1] == (.seconds, 0))

        // Custom subset: only minutes and seconds (days & hours hidden)
        // 3665s = 61 minutes and 5 seconds
        let minSecOnly: [CampaignTimerUnit: CampaignTimerUnitVisibility] = [
            .days: .hide,
            .hours: .hide,
            .minutes: .show,
            .seconds: .show
        ]
        let resSubset = timerUnitValues(remainingSeconds: 3665, visibility: minSecOnly)
        #expect(resSubset.count == 2)
        #expect(resSubset[0] == (.minutes, 61))
        #expect(resSubset[1] == (.seconds, 5))

        // Smallest configured unit ceiling rounding:
        // When seconds is hidden, 65 seconds rounds up to 2 minutes (120s ceiling)
        let hoursMinOnly: [CampaignTimerUnit: CampaignTimerUnitVisibility] = [
            .days: .hide,
            .hours: .show,
            .minutes: .show,
            .seconds: .hide
        ]
        let roundedRes = timerUnitValues(remainingSeconds: 65, visibility: hoursMinOnly)
        #expect(roundedRes.count == 2)
        #expect(roundedRes[0] == (.hours, 0))
        #expect(roundedRes[1] == (.minutes, 2))
    }

    @Test("timerUnitValues oracle calculates 86399s vs 86400s threshold transitions and unit rollups")
    func timerUnitValuesThresholdTransitionOracle() {
        let allUnits: [CampaignTimerUnit: CampaignTimerUnitVisibility] = [
            .days: .show,
            .hours: .show,
            .minutes: .show,
            .seconds: .show
        ]
        let autoHideDays: [CampaignTimerUnit: CampaignTimerUnitVisibility] = [
            .days: .autoHide,
            .hours: .show,
            .minutes: .show,
            .seconds: .show
        ]
        let daysOnly: [CampaignTimerUnit: CampaignTimerUnitVisibility] = [
            .days: .show,
            .hours: .hide,
            .minutes: .hide,
            .seconds: .hide
        ]

        // 86,399s is 0d 23h 59m 59s
        let at86399 = timerUnitValues(remainingSeconds: 86399, visibility: allUnits)
        #expect(at86399[0] == (.days, 0))
        #expect(at86399[1] == (.hours, 23))
        #expect(at86399[2] == (.minutes, 59))
        #expect(at86399[3] == (.seconds, 59))

        // 86,399s with autoHide days suppresses days
        let autoHide86399 = timerUnitValues(remainingSeconds: 86399, visibility: autoHideDays)
        #expect(!autoHide86399.contains { $0.0 == .days })
        #expect(autoHide86399.count == 3)
        #expect(autoHide86399[0] == (.hours, 23))

        // 86,400s flips to 1d 0h 0m 0s and reveals autoHide days
        let at86400 = timerUnitValues(remainingSeconds: 86400, visibility: autoHideDays)
        #expect(at86400.count == 4)
        #expect(at86400[0] == (.days, 1))
        #expect(at86400[1] == (.hours, 0))
        #expect(at86400[2] == (.minutes, 0))
        #expect(at86400[3] == (.seconds, 0))

        // When only days is visible, ceiling rounding rounds 86399s up to 1 day
        let daysCeiling = timerUnitValues(remainingSeconds: 86399, visibility: daysOnly)
        #expect(daysCeiling.count == 1)
        #expect(daysCeiling[0] == (.days, 1))

        // 86401s with only days visible rolls up to 2 days
        let daysRolledUp = timerUnitValues(remainingSeconds: 86401, visibility: daysOnly)
        #expect(daysRolledUp.count == 1)
        #expect(daysRolledUp[0] == (.days, 2))
    }

    @Test("timerLineHeight oracle handles multiplier vs absolute point sizes and invalid values")
    func timerLineHeightOracle() {
        // Multiplier (<= 4) scales with fontSize
        let typo1 = CampaignTypography(fontFamily: nil, fontSize: 16, fontWeight: nil, lineHeight: 1.5, letterSpacing: nil)
        #expect(timerLineHeight(typo1, fallbackSize: 20) == 24.0)

        // Multiplier (<= 4) with nil fontSize falls back to fallbackSize
        let typo2 = CampaignTypography(fontFamily: nil, fontSize: nil, fontWeight: nil, lineHeight: 2.0, letterSpacing: nil)
        #expect(timerLineHeight(typo2, fallbackSize: 18) == 36.0)

        // Absolute point size (> 4) returns exact value
        let typo3 = CampaignTypography(fontFamily: nil, fontSize: 16, fontWeight: nil, lineHeight: 28.0, letterSpacing: nil)
        #expect(timerLineHeight(typo3, fallbackSize: 20) == 28.0)

        // Nil and non-positive lineHeight return nil
        #expect(timerLineHeight(nil, fallbackSize: 20) == nil)
        let typoNil = CampaignTypography(fontFamily: nil, fontSize: 16, fontWeight: nil, lineHeight: nil, letterSpacing: nil)
        #expect(timerLineHeight(typoNil, fallbackSize: 20) == nil)
        let typoZero = CampaignTypography(fontFamily: nil, fontSize: 16, fontWeight: nil, lineHeight: 0, letterSpacing: nil)
        #expect(timerLineHeight(typoZero, fallbackSize: 20) == nil)
        let typoNeg = CampaignTypography(fontFamily: nil, fontSize: 16, fontWeight: nil, lineHeight: -5, letterSpacing: nil)
        #expect(timerLineHeight(typoNeg, fallbackSize: 20) == nil)
        let typoNaN = CampaignTypography(fontFamily: nil, fontSize: 16, fontWeight: nil, lineHeight: .nan, letterSpacing: nil)
        #expect(timerLineHeight(typoNaN, fallbackSize: 20) == nil)
    }

    // MARK: - 3. Timer Subsystem: Countdown Text Formatting

    @Test("canvasTimerCountdownText formats remaining unit values into padded two-digit text spans with colons")
    func timerCountdownTextFormatsTimeBlocks() {
        let style = CampaignCanvasTimerUnitStyle(
            digitTextStyle: CampaignCanvasTextSpan(
                text: "",
                typography: nil,
                color: CampaignColor.literal("#FFFFFFFF"),
                highlightColor: nil,
                italic: false,
                decoration: .none,
                decorationColor: nil,
                decorationThickness: nil,
                actions: []
            ),
            digitTypography: nil,
            digitColor: CampaignColor.literal("#FFFFFFFF"),
            labelTypography: nil,
            labelColor: nil,
            boxFill: .none,
            cornerRadius: .zero
        )
        var layout = CampaignCanvasTimerLayout()
        layout.separatorEnabled = true

        let block = canvasTimerCountdownText(
            values: [(.hours, 1), (.minutes, 1), (.seconds, 5)],
            style: style,
            layout: layout
        )
        #expect(block.spans.map { $0.text } == ["01", ":", "01", ":", "05"])
        #expect(block.plainText == "01:01:05")
    }

    @Test("canvasTimerCountdownText suppresses separator spans when separatorEnabled is false")
    func timerCountdownTextSeparatorSuppression() {
        let style = CampaignCanvasTimerUnitStyle(
            digitTextStyle: CampaignCanvasTextSpan(
                text: "",
                typography: nil,
                color: CampaignColor.literal("#FFFFFFFF"),
                highlightColor: nil,
                italic: false,
                decoration: .none,
                decorationColor: nil,
                decorationThickness: nil,
                actions: []
            ),
            digitTypography: nil,
            digitColor: CampaignColor.literal("#FFFFFFFF"),
            labelTypography: nil,
            labelColor: nil,
            boxFill: .none,
            cornerRadius: .zero
        )
        var layout = CampaignCanvasTimerLayout()
        layout.separatorEnabled = false

        let block = canvasTimerCountdownText(
            values: [(.hours, 1), (.minutes, 30)],
            style: style,
            layout: layout
        )
        #expect(block.spans.map { $0.text } == ["01", "30"])
    }

    @Test("canvasTimerCountdownText applies custom separatorColor and falls back to base digit color")
    func timerCountdownTextSeparatorColor() {
        let style = CampaignCanvasTimerUnitStyle(
            digitTextStyle: CampaignCanvasTextSpan(
                text: "",
                typography: nil,
                color: CampaignColor.literal("#FFFFFFFF"),
                highlightColor: nil,
                italic: false,
                decoration: .none,
                decorationColor: nil,
                decorationThickness: nil,
                actions: []
            ),
            digitTypography: nil,
            digitColor: CampaignColor.literal("#FFFFFFFF"),
            labelTypography: nil,
            labelColor: nil,
            boxFill: .none,
            cornerRadius: .zero
        )

        var customLayout = CampaignCanvasTimerLayout()
        customLayout.separatorEnabled = true
        customLayout.separatorColor = CampaignColor.literal("#FFEF4444")
        let customBlock = canvasTimerCountdownText(
            values: [(.minutes, 5), (.seconds, 0)],
            style: style,
            layout: customLayout
        )
        #expect(customBlock.spans.count == 3)
        #expect(customBlock.spans[1].text == ":")
        #expect(customBlock.spans[1].color == CampaignColor.literal("#FFEF4444"))

        var fallbackLayout = CampaignCanvasTimerLayout()
        fallbackLayout.separatorEnabled = true
        let fallbackBlock = canvasTimerCountdownText(
            values: [(.minutes, 5), (.seconds, 0)],
            style: style,
            layout: fallbackLayout
        )
        #expect(fallbackBlock.spans[1].color == CampaignColor.literal("#FFFFFFFF"))
    }

    // MARK: - 4. Visual Goldens

    @Test("timer renderer matches visual golden", .tags(.golden))
    func timerRendererVisualGolden() throws {
        guard let widget = try parsedTimer([
            "preset": "unitBoxes",
            "separator": ":",
            "units": [
                "days": "autoHide",
                "hours": true,
                "minutes": true,
                "seconds": true
            ],
            "labels": [
                "hours": "HRS",
                "minutes": "MIN",
                "seconds": "SEC"
            ],
            "digitColor": "#FFFFFFFF",
            "labelColor": "#FF94A3B8",
            "boxFill": ["type": "solid", "color": "#FF1E293B"],
            "cornerRadius": 8
        ]) else {
            Issue.record("Failed to parse timer")
            return
        }

        let window = mount(widget: widget, timerRemainingSeconds: 3665)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("timer renderer renders zero state gracefully without collapsing digits", .tags(.golden))
    func timerRendererZeroStateVisualGolden() throws {
        guard let widget = try parsedTimer([
            "preset": "unitBoxes",
            "separator": ":",
            "units": [
                "days": false,
                "hours": true,
                "minutes": true,
                "seconds": true
            ],
            "labels": [
                "hours": "HRS",
                "minutes": "MIN",
                "seconds": "SEC"
            ],
            "digitColor": "#FFFFFFFF",
            "labelColor": "#FF94A3B8",
            "boxFill": ["type": "solid", "color": "#FF0F172A"],
            "cornerRadius": 8
        ]) else {
            Issue.record("Failed to parse timer")
            return
        }

        let window = mount(widget: widget, timerRemainingSeconds: 0)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("timer renderer handles minutes and seconds only with custom styling and separator", .tags(.golden))
    func timerRendererMinutesSecondsOnlyVisualGolden() throws {
        guard let widget = try parsedTimer([
            "preset": "unitBoxes",
            "separator": ":",
            "separatorEnabled": true,
            "separatorColor": "#FFEF4444",
            "units": [
                "days": false,
                "hours": false,
                "minutes": true,
                "seconds": true
            ],
            "labels": [
                "minutes": "MIN",
                "seconds": "SEC"
            ],
            "digitColor": "#FFFFFFFF",
            "labelColor": "#FFCBD5E1",
            "boxFill": ["type": "solid", "color": "#FF334155"],
            "cornerRadius": 14
        ]) else {
            Issue.record("Failed to parse timer")
            return
        }

        let window = mount(widget: widget, timerRemainingSeconds: 754)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    // MARK: - Test Helpers

    private func parsedTimer(
        _ props: [String: Any],
        box: [String: Any] = [:]
    ) throws -> CampaignCanvasWidget? {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 200,
            "children": [
                [
                    "kind": "widget",
                    "id": "timer1",
                    "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 0.3],
                    "widget": [
                        "type": "digia/timer",
                        "containerProps": box,
                        "props": props
                    ]
                ]
            ]
        ])
        guard let first = canvas.children.first, case .widget(_, _, let widget) = first else {
            return nil
        }
        return widget
    }

    private func mount(
        widget: CampaignCanvasWidget,
        timerRemainingSeconds: Int64? = nil,
        isDark: Bool = false,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void = { _ in }
    ) -> UIWindow {
        let canvas = CampaignCanvas(
            version: 2,
            width: 360,
            height: 120,
            background: .solid(.literal("#FFFFFFFF")),
            children: [
                .widget(id: "timer-widget", rect: CampaignCanvasRect(x: 0, y: 0, width: 360, height: 120), widget: widget)
            ]
        )
        return mount(canvas: canvas, timerRemainingSeconds: timerRemainingSeconds, isDark: isDark, onAction: onAction)
    }

    private func mount(
        canvas: CampaignCanvas,
        timerRemainingSeconds: Int64? = nil,
        isDark: Bool = false,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void = { _ in }
    ) -> UIWindow {
        ComponentTestHost.mountCanvas(
            canvas,
            isDark: isDark,
            timerRemainingSeconds: timerRemainingSeconds,
            onAction: onAction
        ).window
    }

    private func unmount(_ window: UIWindow) {
        ComponentTestHost.unmount(window)
    }
}
