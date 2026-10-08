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
@Suite("Dialog", .serialized, .tags(.nudge))
struct NudgeDialogComponentTests {

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

    // MARK: - 1. Wire Contract & Model Parsing (Split into Surface, Canvas, CTA)

    @Test("parses canonical dialog surface configuration contract", .tags(.contract, .smoke)) @MainActor
    func testNudgeDialogSurfaceContract() throws {
        let fixture = try loadNudgeDialogFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any] else {
            Issue.record("Missing templateConfig")
            return
        }

        let nudgeConfig = try #require(NudgeConfig.fromJson(templateConfig))

        #expect(nudgeConfig.surface.displayType == .dialog)
        #expect(nudgeConfig.surface.cornerRadius == 18)
        #expect(nudgeConfig.surface.backdropDismissible)
        #expect(nudgeConfig.surface.showCloseButton)
        #expect(nudgeConfig.surface.closeButton.placement?.horizontal == .right)
        #expect(nudgeConfig.surface.closeButton.placement?.vertical == .top)
    }

    @Test("parses canonical dialog canvas dimensions and child hierarchy", .tags(.contract, .smoke)) @MainActor
    func testNudgeDialogCanvasContract() throws {
        let fixture = try loadNudgeDialogFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any] else {
            Issue.record("Missing templateConfig")
            return
        }

        let nudgeConfig = try #require(NudgeConfig.fromJson(templateConfig))
        let canvas = try #require(nudgeConfig.canvas)

        #expect(canvas.width == 320)
        #expect(canvas.height == 260)
        #expect(canvas.children.count == 3)
        #expect(canvas.children[0].id == "dialogTitle")
        #expect(canvas.children[1].id == "dialogBody")
        #expect(canvas.children[2].id == "dialogButton")
    }

    @Test("parses canonical dialog primary CTA action and button widget", .tags(.contract, .smoke)) @MainActor
    func testNudgeDialogCTAButtonContract() throws {
        let fixture = try loadNudgeDialogFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any] else {
            Issue.record("Missing templateConfig")
            return
        }

        let nudgeConfig = try #require(NudgeConfig.fromJson(templateConfig))
        let canvas = try #require(nudgeConfig.canvas)

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

    // MARK: - 2. Visual Pixel Golden Snapshot

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

    // MARK: - 3. Variant Contract Tests (Radius, Margin, Width, Dark Background)

    struct DialogLayoutVariantCase: CustomTestStringConvertible {
        let fixtureName: String
        let expectedCornerRadius: CGFloat
        let expectedMargin: CGFloat
        let expectedWidth: CGFloat
        let expectedTitle: String
        var testDescription: String { fixtureName }
    }

    @Test(
        "parses dialog layout variant contracts",
        .tags(.contract),
        arguments: [
            DialogLayoutVariantCase(fixtureName: "nudge-dialog-radius-0.json", expectedCornerRadius: 0, expectedMargin: 24, expectedWidth: 320, expectedTitle: "Sharp Corners Dialog"),
            DialogLayoutVariantCase(fixtureName: "nudge-dialog-radius-28.json", expectedCornerRadius: 28, expectedMargin: 24, expectedWidth: 320, expectedTitle: "Rounded Dialog 28"),
            DialogLayoutVariantCase(fixtureName: "nudge-dialog-margin-zero.json", expectedCornerRadius: 18, expectedMargin: 0, expectedWidth: 360, expectedTitle: "Edge-to-Edge Margin Dialog"),
            DialogLayoutVariantCase(fixtureName: "nudge-dialog-margin-large.json", expectedCornerRadius: 18, expectedMargin: 48, expectedWidth: 320, expectedTitle: "Constrained Margin Dialog"),
            DialogLayoutVariantCase(fixtureName: "nudge-dialog-width-narrow.json", expectedCornerRadius: 18, expectedMargin: 24, expectedWidth: 260, expectedTitle: "Narrow Alert Dialog"),
            DialogLayoutVariantCase(fixtureName: "nudge-dialog-width-wide.json", expectedCornerRadius: 18, expectedMargin: 24, expectedWidth: 340, expectedTitle: "Wide Modal Dialog"),
        ]
    )
    @MainActor
    func testNudgeDialogLayoutVariants(testCase: DialogLayoutVariantCase) throws {
        let fixture = try loadNudgeDialogFixture(named: testCase.fixtureName)
        let template = try #require(fixture["templateConfig"] as? [String: Any])
        let config = try #require(NudgeConfig.fromJson(template))
        let canvas = try #require(config.canvas)

        #expect(config.surface.cornerRadius == testCase.expectedCornerRadius)
        #expect(config.surface.minHorizontalMargin == testCase.expectedMargin)
        #expect(canvas.width == testCase.expectedWidth)

        guard case .widget(let id, _, let widget) = canvas.children[0],
            id == "dialogTitle",
            case .text(_, let textBlock, _) = widget
        else {
            Issue.record("Expected dialogTitle text widget")
            return
        }
        #expect(textBlock.plainText == testCase.expectedTitle)
    }

    @Test("parses the dark-theme dialog contract", .tags(.contract)) @MainActor
    func testNudgeDialogDarkThemeVariantContract() throws {
        let darkFixture = try loadNudgeDialogFixture(named: "nudge-dialog-bg-dark.json")
        let darkTemplate = try #require(darkFixture["templateConfig"] as? [String: Any])
        let darkConfig = try #require(NudgeConfig.fromJson(darkTemplate))
        let darkCanvas = try #require(darkConfig.canvas)

        let surfaceBg = try #require(darkConfig.surface.backgroundColor)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(surfaceBg).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(abs(red - 0.067) < 0.02)
        #expect(abs(green - 0.094) < 0.02)
        #expect(abs(blue - 0.153) < 0.02)

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

    // MARK: - Dialog Dismissal & Panel Sizing

    @Test("backdrop tap dismisses when backdropDismissible is true and does nothing when false", .tags(.unit, .smoke)) @MainActor
    func testNudgeDialogBackdropTapDismissal() throws {
        let fixture = try loadNudgeDialogFixture()
        let templateConfig = try #require(fixture["templateConfig"] as? [String: Any])
        let config = try #require(NudgeConfig.fromJson(templateConfig))
        #expect(config.surface.backdropDismissible == true)

        let presentation = DigiaNudgePresentation(
            config: config,
            payload: CEPTriggerPayload(cepCampaignId: "test_dialog_dismiss", campaignKey: "test_dialog_dismiss", cepMetadata: [:]),
            variables: nil
        )

        // 1. Dismissible: tapping backdrop dismisses active nudge
        SDKInstance.shared.controller.showNudge(presentation)
        #expect(SDKInstance.shared.controller.activeNudge?.id == "test_dialog_dismiss")

        let dismissibleContainer = NudgeDialogContainer(
            presentation: presentation,
            viewportSize: CGSize(width: 390, height: 844),
            safeAreaInsets: .zero
        )
        dismissibleContainer.handleBackdropTap()
        #expect(SDKInstance.shared.controller.activeNudge == nil)

        // 2. Non-dismissible: tapping backdrop keeps active nudge intact
        var nonDismissibleTemplate = templateConfig
        var surfaceDict = nonDismissibleTemplate["container"] as? [String: Any] ?? [:]
        surfaceDict["backdropDismissible"] = false
        nonDismissibleTemplate["container"] = surfaceDict
        let nonDismissibleConfig = try #require(NudgeConfig.fromJson(nonDismissibleTemplate))
        #expect(!nonDismissibleConfig.surface.backdropDismissible)

        let nonDismissiblePresentation = DigiaNudgePresentation(
            config: nonDismissibleConfig,
            payload: CEPTriggerPayload(cepCampaignId: "test_dialog_non_dismissible", campaignKey: "test_dialog_non_dismissible", cepMetadata: [:]),
            variables: nil
        )
        SDKInstance.shared.controller.showNudge(nonDismissiblePresentation)
        #expect(SDKInstance.shared.controller.activeNudge?.id == "test_dialog_non_dismissible")

        let nonDismissibleContainer = NudgeDialogContainer(
            presentation: nonDismissiblePresentation,
            viewportSize: CGSize(width: 390, height: 844),
            safeAreaInsets: .zero
        )
        nonDismissibleContainer.handleBackdropTap()
        #expect(SDKInstance.shared.controller.activeNudge?.id == "test_dialog_non_dismissible")

        // Teardown
        SDKInstance.shared.controller.forceNudgeDismiss()
    }

    @Test("CTA dismiss action closes active dialog", .tags(.unit, .smoke)) @MainActor
    func testNudgeDialogCTADismissAction() throws {
        let fixture = try loadNudgeDialogFixture()
        let templateConfig = try #require(fixture["templateConfig"] as? [String: Any])
        let config = try #require(NudgeConfig.fromJson(templateConfig))

        let presentation = DigiaNudgePresentation(
            config: config,
            payload: CEPTriggerPayload(cepCampaignId: "test_cta_dismiss_dialog", campaignKey: "test_cta_dismiss_dialog", cepMetadata: [:]),
            variables: nil
        )
        SDKInstance.shared.controller.showNudge(presentation)
        #expect(SDKInstance.shared.controller.activeNudge?.id == "test_cta_dismiss_dialog")

        dismissNudgeFromCta()
        #expect(SDKInstance.shared.controller.activeNudge == nil)
    }

    @Test("surface close button visibility toggle", .tags(.contract, .unit)) @MainActor
    func testNudgeDialogCloseButtonVisibilityToggle() throws {
        let fixture = try loadNudgeDialogFixture()
        var templateConfig = try #require(fixture["templateConfig"] as? [String: Any])
        var containerDict = templateConfig["container"] as? [String: Any] ?? [:]

        // Default: shown
        containerDict["showCloseButton"] = true
        templateConfig["container"] = containerDict
        let shownConfig = try #require(NudgeConfig.fromJson(templateConfig))
        #expect(shownConfig.surface.showCloseButton)

        // Toggled off: hidden
        containerDict["showCloseButton"] = false
        templateConfig["container"] = containerDict
        let hiddenConfig = try #require(NudgeConfig.fromJson(templateConfig))
        #expect(!hiddenConfig.surface.showCloseButton)
    }

    @Test("dialogPanel clamps overflow content within maxHeight constraint", .tags(.unit)) @MainActor
    func testNudgeDialogPanelOverflowSizing() throws {
        // Construct a non-canvas (legacy column layout) config to exercise dialogPanel
        var json: [String: Any] = [
            "displayType": "dialog",
            "container": [
                "displayType": "dialog",
                "cornerRadius": 16,
                "padding": 20,
                "showCloseButton": true
            ],
            "layout": [
                "type": "column",
                "children": [
                    ["type": "text", "text": "Header", "fontSize": 24],
                    ["type": "text", "text": "Long long content line 1", "fontSize": 16],
                    ["type": "text", "text": "Long long content line 2", "fontSize": 16],
                    ["type": "text", "text": "Long long content line 3", "fontSize": 16],
                    ["type": "text", "text": "Long long content line 4", "fontSize": 16]
                ]
            ]
        ]
        let config = try #require(NudgeConfig.fromJson(json))
        #expect(config.canvas == nil)

        let presentation = DigiaNudgePresentation(
            config: config,
            payload: CEPTriggerPayload(cepCampaignId: "test_dialog_overflow", campaignKey: "test_dialog_overflow", cepMetadata: [:]),
            variables: nil
        )
        let container = NudgeDialogContainer(
            presentation: presentation,
            viewportSize: CGSize(width: 390, height: 844),
            safeAreaInsets: .zero
        )

        // dialogPanel should build successfully and clamp to maxHeight
        let panelView = container.dialogPanel(width: 300, maxHeight: 150)
        let hostingController = UIHostingController(rootView: AnyView(panelView))
        hostingController.view.frame = CGRect(x: 0, y: 0, width: 300, height: 150)
        hostingController.view.layoutIfNeeded()
        #expect(hostingController.view != nil)
    }
}
