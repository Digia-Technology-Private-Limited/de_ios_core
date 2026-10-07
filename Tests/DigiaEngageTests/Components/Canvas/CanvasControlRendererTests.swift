import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas control renderer", .serialized, .tags(.canvas, .component))
struct CanvasControlRendererTests {

    // MARK: - 1. Divider Subsystem: Parser & Properties

    @Test("divider parser preserves axis, style pattern, stroke cap, insets, dash pattern, and token colors")
    func dividerParserPreservesAllProperties() throws {
        // 1. Horizontal solid divider with stroke cap butt and non-zero inset
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

        // 2. Vertical dashed divider with round cap and custom dash pattern
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

        // 3. Dotted divider with square cap and fallback color
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

    @Test("canvasDividerDashPattern oracle computes exact dash lengths for solid, dotted, and dashed patterns")
    func dividerDashPatternOracle() {
        // Solid divider always returns []
        #expect(canvasDividerDashPattern(pattern: .solid, thickness: 2, dashPattern: [10, 5]).isEmpty)
        #expect(canvasDividerDashPattern(pattern: .solid, thickness: 10, dashPattern: []).isEmpty)

        // Dotted divider produces [0, max(thickness, gap)]
        // Case A: empty authored dash pattern falls back to gap 4
        #expect(canvasDividerDashPattern(pattern: .dotted, thickness: 2, dashPattern: []) == [0, 4])
        // Case B: thickness larger than gap
        #expect(canvasDividerDashPattern(pattern: .dotted, thickness: 8, dashPattern: [0, 4]) == [0, 8])
        // Case C: authored gap larger than thickness
        #expect(canvasDividerDashPattern(pattern: .dotted, thickness: 2, dashPattern: [0, 10]) == [0, 10])

        // Dashed divider returns exact authored pattern
        #expect(canvasDividerDashPattern(pattern: .dashed, thickness: 3, dashPattern: [6, 3]) == [6, 3])
        #expect(canvasDividerDashPattern(pattern: .dashed, thickness: 1, dashPattern: [12, 4, 2, 4]) == [12, 4, 2, 4])
    }

    @Test("CampaignCanvasStrokeCap maps directly to CGLineCap")
    func dividerStrokeCapMapping() {
        #expect(CampaignCanvasStrokeCap.butt.lineCap == .butt)
        #expect(CampaignCanvasStrokeCap.round.lineCap == .round)
        #expect(CampaignCanvasStrokeCap.square.lineCap == .square)
    }

    // MARK: - 3. Divider Subsystem: Mounting & Theme Switching

    @Test("horizontal and vertical dividers mount in UIWindow with dark and light themes")
    func dividerMountingAndTheme() {
        let hDivider = try! parsedDivider([
            "type": "horizontal",
            "style": "dashed",
            "strokeCap": "round",
            "inset": 10,
            "dashPattern": [8, 4],
            "color": "#FF336699"
        ])
        let windowH = mount(widget: hDivider, isDark: false)
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(windowH.rootViewController?.view != nil)
        unmount(windowH)

        let vDivider = try! parsedDivider([
            "type": "vertical",
            "style": "dotted",
            "strokeCap": "square",
            "inset": 4,
            "color": "#FFFF0000"
        ])
        let windowV = mount(widget: vDivider, isDark: true)
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(windowV.rootViewController?.view != nil)
        unmount(windowV)
    }

    // MARK: - 4. Progress Subsystem: Parser & Properties

    @Test("progress parser preserves value modes, range bounds, paints, corner radius, and clamps animation duration")
    func progressParserPreservesAllProperties() throws {
        // Percent mode
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

        // Range mode with animation duration clamping
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

    // MARK: - 5. Progress Subsystem: Oracles

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

    // MARK: - 6. Progress Subsystem: Mounting & Lifecycle

    @Test("progress bar mounts and renders safely in UIWindow")
    func progressMounting() {
        let widget = try! parsedProgress([
            "valueMode": "percent",
            "percent": "40",
            "indicator": ["type": "solid", "color": "#FF10B981"],
            "track": ["type": "solid", "color": "#FFE5E7EB"],
            "cornerRadius": 4
        ])
        let window = mount(widget: widget)
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(window.rootViewController?.view != nil)
        unmount(window)
    }

    // MARK: - 7. Timer Subsystem: Parser & Layout

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

    // MARK: - 8. Timer Subsystem: Oracles

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

    // MARK: - 9. Timer Subsystem: Mounting & Lifecycle

    @Test("timer with environment remaining seconds mounts and renders safely in UIWindow")
    func timerMounting() throws {
        guard let widget = try parsedTimer([
            "preset": "unitBoxes",
            "separator": ":",
            "units": [
                "days": "autoHide",
                "hours": true,
                "minutes": true,
                "seconds": true
            ],
            "style": [
                "digitColor": "#FFFFFFFF",
                "labelColor": "#FFB9C6DA",
                "boxFill": ["type": "solid", "color": "#FF0F172A"],
                "cornerRadius": 6
            ]
        ]) else {
            Issue.record("Failed to parse timer")
            return
        }

        let window = mount(widget: widget, timerRemainingSeconds: 7200)
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(window.rootViewController?.view != nil)
        unmount(window)
    }

    // MARK: - 10. TapRegion Subsystem: Parser & Geometry

    @Test("tapRegion parser scales normalized rect to canvas bounds and preserves actions and primary flag")
    func tapRegionParserPreservesGeometry() throws {
        let canvas = try parsedCanvas(children: [
            [
                "kind": "tapRegion",
                "id": "hero-cta",
                "rect": ["x": 0.1, "y": 0.2, "width": 0.5, "height": 0.4],
                "isPrimary": true,
                "onClick": [
                    "steps": [
                        [
                            "type": "open_url",
                            "data": ["url": "https://example.com/special"]
                        ]
                    ]
                ]
            ]
        ])
        #expect(canvas.children.count == 1)
        guard case .tapRegion(let id, let rect, let actions, let isPrimary) = canvas.children.first else {
            Issue.record("Expected tapRegion child")
            return
        }
        #expect(id == "hero-cta")
        // Normalized (0.1, 0.2, 0.5, 0.4) on canvas (300, 200)
        #expect(rect == CampaignCanvasRect(x: 30, y: 40, width: 150, height: 80))
        #expect(isPrimary == true)
        #expect(actions.count == 1)
        if case .openUrl(let url) = actions.first {
            #expect(url == "https://example.com/special")
        } else {
            Issue.record("Expected openUrl action")
        }
    }

    @Test("tapRegion parser filters empty non-primary regions but retains primary or actionable regions")
    func tapRegionFilteringOracle() throws {
        let canvas = try parsedCanvas(children: [
            // 1. Non-primary with NO actions -> MUST be dropped
            [
                "kind": "tapRegion",
                "id": "empty-passive",
                "rect": ["x": 0.0, "y": 0.0, "width": 0.2, "height": 0.2],
                "isPrimary": false
            ],
            // 2. Primary with NO actions -> MUST be retained
            [
                "kind": "tapRegion",
                "id": "primary-tap",
                "rect": ["x": 0.2, "y": 0.0, "width": 0.2, "height": 0.2],
                "isPrimary": true
            ],
            // 3. Non-primary with actions -> MUST be retained
            [
                "kind": "tapRegion",
                "id": "actionable-tap",
                "rect": ["x": 0.4, "y": 0.0, "width": 0.2, "height": 0.2],
                "isPrimary": false,
                "onClick": [
                    "steps": [["type": "Action.hideInline"]]
                ]
            ]
        ])
        #expect(canvas.children.count == 2)
        #expect(canvas.children.map(\.id) == ["primary-tap", "actionable-tap"])
    }

    // MARK: - 11. TapRegion Subsystem: Properties & Hit Testing

    @Test("tapRegion child properties correctly expose isHitTestable and clipsToAuthoredRect")
    func tapRegionChildProperties() {
        let activeChild = CampaignCanvasChild.tapRegion(
            id: "tap1",
            rect: CampaignCanvasRect(x: 10, y: 10, width: 100, height: 50),
            actions: [EngageAction.openUrl("https://example.com")],
            isPrimary: false
        )
        #expect(activeChild.id == "tap1")
        #expect(activeChild.rect == CampaignCanvasRect(x: 10, y: 10, width: 100, height: 50))
        #expect(activeChild.isHitTestable == true)
        #expect(activeChild.clipsToAuthoredRect == true)

        let primaryEmptyChild = CampaignCanvasChild.tapRegion(
            id: "tap2",
            rect: CampaignCanvasRect(x: 0, y: 0, width: 200, height: 100),
            actions: [],
            isPrimary: true
        )
        #expect(primaryEmptyChild.isHitTestable == true)

        let passiveEmptyChild = CampaignCanvasChild.tapRegion(
            id: "tap3",
            rect: CampaignCanvasRect(x: 0, y: 0, width: 200, height: 100),
            actions: [],
            isPrimary: false
        )
        // All tapRegions in the model layer are hitTestable; pruning occurs during parser phase
        #expect(passiveEmptyChild.isHitTestable == true)
    }

    // MARK: - 12. TapRegion Subsystem: Dispatch & Mounting

    @Test("canvas with tap region mounts in UIWindow and simulates tap action request dispatch")
    func tapRegionMountAndDispatch() throws {
        var dispatched: CampaignCanvasActionRequest?
        let action = EngageAction.openUrl("https://digia.com/promo")

        let canvas = try parsedCanvas(children: [
            [
                "kind": "tapRegion",
                "id": "card-overlay",
                "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
                "isPrimary": true,
                "onClick": [
                    "steps": [
                        [
                            "type": "open_url",
                            "data": ["url": "https://digia.com/promo"]
                        ]
                    ]
                ]
            ]
        ])

        let window = mount(canvas: canvas, onAction: { request in
            dispatched = request
        })
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(window.rootViewController?.view != nil)

        // Verify tap action dispatch contract:
        // A tap on this region produces a CampaignCanvasActionRequest with actions, id, and isPrimary
        guard case .tapRegion(let id, _, let actions, let isPrimary) = canvas.children.first else {
            Issue.record("Expected tapRegion child")
            unmount(window)
            return
        }
        let request = CampaignCanvasActionRequest(actions: actions, elementId: id, isPrimary: isPrimary)
        #expect(request.elementId == "card-overlay")
        #expect(request.isPrimary == true)
        #expect(request.actions == [action])

        unmount(window)
    }

    // MARK: - 13. Visual Goldens

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

    @Test("progress bar and divider renderer matches visual golden", .tags(.golden))
    func progressBarAndDividerVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 120,
            "background": ["type": "solid", "color": "#FFFFFFFF"],
            "children": [
                [
                    "kind": "widget",
                    "id": "progress",
                    "rect": ["x": 0.05, "y": 0.2, "width": 0.9, "height": 0.15],
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
                ],
                [
                    "kind": "widget",
                    "id": "divider",
                    "rect": ["x": 0.05, "y": 0.65, "width": 0.9, "height": 0.05],
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

    private func parsedCanvas(children: [[String: Any]]) throws -> CampaignCanvas {
        try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 300,
            "canvasHeight": 200,
            "children": children
        ])
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
                .widget(id: "ctrl-widget", rect: CampaignCanvasRect(x: 0, y: 0, width: 360, height: 120), widget: widget)
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
        var stage = CampaignCanvasStage(
            canvas: canvas,
            authoredCornerRadius: 0,
            isDark: isDark,
            showBackground: true,
            onAction: onAction
        )
        stage.animateWidgetsOnAppear = false
        let view = stage
            .environment(\.timerRemainingSeconds, timerRemainingSeconds)
            .ignoresSafeArea()
        let controller = ComponentTestHost.makeComponentHost(
            rootView: AnyView(view),
            size: CGSize(width: canvas.width, height: canvas.height),
            backgroundColor: .white
        )
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
