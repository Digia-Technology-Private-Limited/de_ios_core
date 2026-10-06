import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Component test for the canonical Nudge Dialog scenario (`test_nudge_dialog`).
///
/// Uses the canonical `nudge-dialog.json` fixture for Tier-2 verification of:
/// 1. Wire schema and layout parsing into `NudgeConfig` and `CampaignCanvas`
/// 2. Child widget attributes and CTA action metadata
/// 3. Visual pixel snapshot diffing (`.image`)
extension NudgeComponentTests {
@Suite("Dialog")
struct Dialog {

    private func loadNudgeDialogFixture(named fileName: String = "nudge-dialog.json") throws
        -> [String: Any]
    {
        guard
            let fixture = FixtureLoader.loadFixture(
                campaignType: "nudge_dialog",
                fileName: fileName
            )
        else {
            Issue.record("Failed to load fixture for nudge_dialog/\(fileName)")
            return [:]
        }
        return fixture
    }

    @Test("parses the canonical dialog model and CTA contract", .tags(.contract, .smoke)) @MainActor
    func testNudgeDialogModelParsingAndContract() throws {
        let fixture = try loadNudgeDialogFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any] else {
            Issue.record("Missing templateConfig")
            return
        }

        let nudgeConfig = try #require(NudgeConfig.fromJson(templateConfig))

        // Surface / container assertions
        #expect(nudgeConfig.surface.displayType == .dialog)
        #expect(nudgeConfig.surface.cornerRadius == 18)
        #expect(nudgeConfig.surface.backdropDismissible)
        #expect(nudgeConfig.surface.showCloseButton)
        #expect(nudgeConfig.surface.closeButton.placement?.horizontal == .right)
        #expect(nudgeConfig.surface.closeButton.placement?.vertical == .top)

        // Canvas assertions
        let canvas = try #require(nudgeConfig.canvas)
        #expect(canvas.width == 320)
        #expect(canvas.height == 260)
        #expect(canvas.children.count == 3)

        // Verify child nodes order & IDs
        #expect(canvas.children[0].id == "dialogTitle")
        #expect(canvas.children[1].id == "dialogBody")
        #expect(canvas.children[2].id == "dialogButton")

        guard case .widget(let id, _, let widget) = canvas.children[2],
            id == "dialogButton",
            case .button(_, let label, _, _, _, let isPrimary, _, _, let actions, _) = widget
        else {
            Issue.record("Expected dialogButton button widget")
            return
        }
        #expect(label.plainText == "Got It")
        #expect(isPrimary)
        #expect(actions == [.dismiss])
    }

    // MARK: - 2. Hierarchy and Visual Golden Snapshots

    @Test("matches the production dialog view hierarchy snapshot", .tags(.component)) @MainActor
    func testNudgeDialogComponentHierarchy() throws {
        let fixture = try loadNudgeDialogFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            nudgeConfig.canvas != nil
        else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealDialogHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax
        )
        defer {
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        assertHierarchy(matching: hostView)
    }

    @Test("matches the production dialog visual golden", .tags(.golden)) @MainActor
    func testNudgeDialogVisualImageGolden() throws {
        let fixture = try loadNudgeDialogFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            nudgeConfig.canvas != nil
        else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealDialogHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax
        )
        defer {
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    // MARK: - 3. Device Dialog Golden (.image on device with REAL production NudgeDialogContainer)

    @Test("matches the production dialog device golden", .tags(.golden, .smoke)) @MainActor
    func testNudgeDialogDeviceGolden() throws {
        let fixture = try loadNudgeDialogFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            nudgeConfig.canvas != nil
        else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        // Renders the production dialog overlay on the pinned iPhone 17 Pro Max viewport.
        let hostView = ComponentTestHost.makeRealDialogHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer {
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    // MARK: - Maestro Variant Tests (Radius, Margin, Width, Background)

    // MARK: 1. Radius Change Variants (nudge-dialog-radius-0 & nudge-dialog-radius-28)

    @Test("parses sharp and rounded dialog radius contracts", .tags(.contract)) @MainActor
    func testNudgeDialogRadiusChangeVariantContract() throws {
        // Variant A: Sharp corners (cornerRadius: 0)
        let sharpFixture = try loadNudgeDialogFixture(named: "nudge-dialog-radius-0.json")
        guard let sharpTemplate = sharpFixture["templateConfig"] as? [String: Any],
            let sharpConfig = NudgeConfig.fromJson(sharpTemplate),
            let sharpCanvas = sharpConfig.canvas
        else {
            Issue.record("Failed to parse sharp corners nudge config")
            return
        }

        #expect(sharpConfig.surface.cornerRadius == 0)
        #expect(sharpCanvas.width == 320)
        #expect(sharpCanvas.height == 260)

        // Verify title text node
        guard case .widget(let titleId, _, let titleWidget) = sharpCanvas.children[0],
            titleId == "dialogTitle",
            case .text(_, let textBlock, _) = titleWidget
        else {
            Issue.record("Expected dialogTitle text widget")
            return
        }
        #expect(textBlock.plainText == "Sharp Corners Dialog")

        // Variant B: Rounded corners (cornerRadius: 28)
        let roundedFixture = try loadNudgeDialogFixture(named: "nudge-dialog-radius-28.json")
        guard let roundedTemplate = roundedFixture["templateConfig"] as? [String: Any],
            let roundedConfig = NudgeConfig.fromJson(roundedTemplate),
            let roundedCanvas = roundedConfig.canvas
        else {
            Issue.record("Failed to parse rounded corners nudge config")
            return
        }

        #expect(roundedConfig.surface.cornerRadius == 28)
        #expect(roundedCanvas.width == 320)
        #expect(roundedCanvas.height == 260)

        // Verify title text node
        guard
            case .widget(let roundedTitleId, _, let roundedTitleWidget) = roundedCanvas.children[0],
            roundedTitleId == "dialogTitle",
            case .text(_, let roundedTextBlock, _) = roundedTitleWidget
        else {
            Issue.record("Expected dialogTitle text widget")
            return
        }
        #expect(roundedTextBlock.plainText == "Rounded Dialog 28")
    }

    // MARK: 2. Margin Change Variants (nudge-dialog-margin-zero & nudge-dialog-margin-large)

    @Test("parses zero and constrained dialog margin contracts", .tags(.contract)) @MainActor
    func testNudgeDialogMarginChangeVariantContract() throws {
        // Variant A: Edge-to-edge zero margin (minHorizontalMargin: 0)
        let zeroMarginFixture = try loadNudgeDialogFixture(named: "nudge-dialog-margin-zero.json")
        guard let zeroTemplate = zeroMarginFixture["templateConfig"] as? [String: Any],
            let zeroConfig = NudgeConfig.fromJson(zeroTemplate),
            let zeroCanvas = zeroConfig.canvas
        else {
            Issue.record("Failed to parse zero margin nudge config")
            return
        }

        #expect(zeroConfig.surface.minHorizontalMargin == 0)
        #expect(zeroCanvas.width == 360)
        #expect(zeroCanvas.height == 260)

        #expect(zeroConfig.designWidth == 360)

        guard case .widget(let zeroTitleId, _, let zeroTitleWidget) = zeroCanvas.children[0],
            zeroTitleId == "dialogTitle",
            case .text(_, let zeroTextBlock, _) = zeroTitleWidget
        else {
            Issue.record("Expected dialogTitle text widget")
            return
        }
        #expect(zeroTextBlock.plainText == "Edge-to-Edge Margin Dialog")

        // Variant B: Large constrained margin (minHorizontalMargin: 48)
        let largeMarginFixture = try loadNudgeDialogFixture(named: "nudge-dialog-margin-large.json")
        guard let largeTemplate = largeMarginFixture["templateConfig"] as? [String: Any],
            let largeConfig = NudgeConfig.fromJson(largeTemplate),
            let largeCanvas = largeConfig.canvas
        else {
            Issue.record("Failed to parse large margin nudge config")
            return
        }

        #expect(largeConfig.surface.minHorizontalMargin == 48)
        #expect(largeCanvas.width == 320)
        #expect(largeCanvas.height == 260)

        #expect(largeConfig.designWidth == 360)

        guard case .widget(let largeTitleId, _, let largeTitleWidget) = largeCanvas.children[0],
            largeTitleId == "dialogTitle",
            case .text(_, let largeTextBlock, _) = largeTitleWidget
        else {
            Issue.record("Expected dialogTitle text widget")
            return
        }
        #expect(largeTextBlock.plainText == "Constrained Margin Dialog")

    }

    // MARK: 3. Width Change Variants (nudge-dialog-width-narrow & nudge-dialog-width-wide)

    @Test("parses narrow and wide dialog width contracts", .tags(.contract)) @MainActor
    func testNudgeDialogWidthChangeVariantContract() throws {
        // Variant A: Narrow alert dialog (canvasWidth: 260)
        let narrowFixture = try loadNudgeDialogFixture(named: "nudge-dialog-width-narrow.json")
        guard let narrowTemplate = narrowFixture["templateConfig"] as? [String: Any],
            let narrowConfig = NudgeConfig.fromJson(narrowTemplate),
            let narrowCanvas = narrowConfig.canvas
        else {
            Issue.record("Failed to parse narrow dialog nudge config")
            return
        }

        #expect(narrowCanvas.width == 260)
        #expect(narrowCanvas.height == 260)

        guard case .widget(let narrowTitleId, _, let narrowTitleWidget) = narrowCanvas.children[0],
            narrowTitleId == "dialogTitle",
            case .text(_, let narrowTextBlock, _) = narrowTitleWidget
        else {
            Issue.record("Expected dialogTitle text widget")
            return
        }
        #expect(narrowTextBlock.plainText == "Narrow Alert Dialog")

        // Variant B: Wide landscape-optimized dialog (canvasWidth: 340)
        let wideFixture = try loadNudgeDialogFixture(named: "nudge-dialog-width-wide.json")
        guard let wideTemplate = wideFixture["templateConfig"] as? [String: Any],
            let wideConfig = NudgeConfig.fromJson(wideTemplate),
            let wideCanvas = wideConfig.canvas
        else {
            Issue.record("Failed to parse wide dialog nudge config")
            return
        }

        #expect(wideCanvas.width == 340)
        #expect(wideCanvas.height == 260)

        guard case .widget(let wideTitleId, _, let wideTitleWidget) = wideCanvas.children[0],
            wideTitleId == "dialogTitle",
            case .text(_, let wideTextBlock, _) = wideTitleWidget
        else {
            Issue.record("Expected dialogTitle text widget")
            return
        }
        #expect(wideTextBlock.plainText == "Wide Modal Dialog")

    }

    // MARK: 4. Dark Background / Surface Variant (nudge-dialog-bg-dark)

    @Test("parses the dark-theme dialog contract", .tags(.contract)) @MainActor
    func testNudgeDialogDarkThemeVariantContract() throws {
        let darkFixture = try loadNudgeDialogFixture(named: "nudge-dialog-bg-dark.json")
        guard let darkTemplate = darkFixture["templateConfig"] as? [String: Any],
            let darkConfig = NudgeConfig.fromJson(darkTemplate),
            let darkCanvas = darkConfig.canvas
        else {
            Issue.record("Failed to parse dark background nudge config")
            return
        }

        // Surface background is decoded from #111827
        let surfaceBg = try #require(darkConfig.surface.backgroundColor)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(surfaceBg).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(abs(red - 0.067) < 0.02)
        #expect(abs(green - 0.094) < 0.02)
        #expect(abs(blue - 0.153) < 0.02)

        // Child button node validation
        guard case .widget(let btnId, _, let btnWidget) = darkCanvas.children[2],
            btnId == "dialogButton",
            case .button(_, let btnLabel, _, _, _, let isPrimary, _, _, let actions, _) = btnWidget
        else {
            Issue.record("Expected dialogButton widget")
            return
        }
        #expect(isPrimary)
        #expect(btnLabel.plainText == "Got It")
        #expect(actions == [.dismiss])

    }

    // MARK: - Maestro Variant Visual Golden Snapshots

    @Test("matches the sharp-corner dialog golden", .tags(.golden)) @MainActor
    func testNudgeDialogRadius0VisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-radius-0.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            nudgeConfig.canvas != nil
        else {
            Issue.record("Failed to parse sharp radius nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealDialogHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer {
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the rounded-corner dialog golden", .tags(.golden)) @MainActor
    func testNudgeDialogRadius28VisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-radius-28.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            nudgeConfig.canvas != nil
        else {
            Issue.record("Failed to parse rounded radius nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealDialogHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer {
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the zero-margin dialog golden", .tags(.golden)) @MainActor
    func testNudgeDialogMarginZeroVisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-margin-zero.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            nudgeConfig.canvas != nil
        else {
            Issue.record("Failed to parse zero margin nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealDialogHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer {
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the large-margin dialog golden", .tags(.golden)) @MainActor
    func testNudgeDialogMarginLargeVisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-margin-large.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            nudgeConfig.canvas != nil
        else {
            Issue.record("Failed to parse large margin nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealDialogHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer {
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the narrow dialog golden", .tags(.golden)) @MainActor
    func testNudgeDialogWidthNarrowVisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-width-narrow.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            nudgeConfig.canvas != nil
        else {
            Issue.record("Failed to parse narrow width nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealDialogHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer {
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the wide dialog golden", .tags(.golden)) @MainActor
    func testNudgeDialogWidthWideVisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-width-wide.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            nudgeConfig.canvas != nil
        else {
            Issue.record("Failed to parse wide width nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealDialogHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer {
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the dark-theme dialog golden", .tags(.golden)) @MainActor
    func testNudgeDialogDarkThemeVisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-bg-dark.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            nudgeConfig.canvas != nil
        else {
            Issue.record("Failed to parse dark background nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealDialogHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer {
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }
}
}
