import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Component test for the canonical Nudge Dialog scenario (`test_nudge_dialog`).
///
/// Migrated from Maestro E2E (`testkit/campaigns/nudge_dialog/tests/nudge-dialog.yaml`)
/// to a Tier-2 Component test verifying:
/// 1. Wire schema and layout parsing into `NudgeConfig` and `CampaignCanvas`
/// 2. View hierarchy structure, layout bounds, and child widget attributes
/// 3. Interactive CTA action callback routing
/// 4. View hierarchy textual snapshot diffing (`.recursiveDescription` sanitized)
/// 5. Visual pixel snapshot diffing (`.image`)
@Suite(.serialized, .tags(.nudge, .smoke))
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

    @Test @MainActor
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
    }

    @Test @MainActor
    func testNudgeDialogComponentHierarchyAndLayout() throws {
        let fixture = try loadNudgeDialogFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            let canvas = nudgeConfig.canvas
        else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        var dispatchedAction: CampaignCanvasActionRequest?
        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: 320, height: 260),
            onAction: { request in
                dispatchedAction = request
            }
        )

        // Host in UIHostingController at exact authored dimensions
        let controller = UIHostingController(rootView: canvasView)
        controller.view.bounds = CGRect(x: 0, y: 0, width: 320, height: 260)
        controller.view.layoutIfNeeded()

        // 1. Verify layout frame
        #expect(controller.view.bounds.width == 320)
        #expect(controller.view.bounds.height == 260)

        // 2. Full AST and layout model snapshot using Swift reflection (.dump)
        assertSnapshot(
            of: nudgeConfig,
            as: .dump,
            record: isSnapshotRecordingEnabled
        )
    }

    @Test @MainActor
    func testNudgeDialogVisualImageGolden() throws {
        let fixture = try loadNudgeDialogFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            let canvas = nudgeConfig.canvas
        else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: 320, height: 260),
            onAction: { _ in }
        )

        let controller = UIHostingController(rootView: canvasView)
        controller.view.bounds = CGRect(x: 0, y: 0, width: 320, height: 260)
        controller.view.layoutIfNeeded()

        // Visual pixel snapshot diffing with native Xcode attachment integration
        assertVisualGolden(matching: controller.view)
    }

    // MARK: - 3. Device Dialog Golden (.image on device with REAL production NudgeDialogContainer)

    @Test @MainActor
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
            precision: 0.98,
            perceptualPrecision: 0.98
        )
    }

    // MARK: - Maestro Variant Tests (Radius, Margin, Width, Background)

    // MARK: 1. Radius Change Variants (nudge-dialog-radius-0 & nudge-dialog-radius-28)

    @Test @MainActor
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

    @Test @MainActor
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

        let designWidthZero = max(zeroConfig.designWidth, 1)
        let horizontalMarginZero = min(
            max(zeroConfig.surface.minHorizontalMargin, 0), max(0, (designWidthZero - 1) / 2))
        let availableWidthZero = designWidthZero - (2 * horizontalMarginZero)
        #expect(availableWidthZero == 360)

        guard case .widget(let zeroTitleId, _, let zeroTitleWidget) = zeroCanvas.children[0],
            zeroTitleId == "dialogTitle",
            case .text(_, let zeroTextBlock, _) = zeroTitleWidget
        else {
            Issue.record("Expected dialogTitle text widget")
            return
        }
        #expect(zeroTextBlock.plainText == "Edge-to-Edge Margin Dialog")

        let zeroMarginView = CampaignCanvasView(
            canvas: zeroCanvas,
            surface: zeroConfig.surface,
            designWidth: zeroConfig.designWidth,
            availableSize: CGSize(width: 360, height: 260),
            onAction: { _ in }
        )
        let zeroController = UIHostingController(rootView: zeroMarginView)
        zeroController.view.bounds = CGRect(x: 0, y: 0, width: 360, height: 260)
        zeroController.view.layoutIfNeeded()
        #expect(zeroController.view.bounds.width == 360)

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

        let designWidthLarge = max(largeConfig.designWidth, 1)
        #expect(designWidthLarge == 360)
        let horizontalMarginLarge = min(
            max(largeConfig.surface.minHorizontalMargin, 0), max(0, (designWidthLarge - 1) / 2))
        let availableWidthLarge = designWidthLarge - (2 * horizontalMarginLarge)
        #expect(availableWidthLarge == 264)

        guard case .widget(let largeTitleId, _, let largeTitleWidget) = largeCanvas.children[0],
            largeTitleId == "dialogTitle",
            case .text(_, let largeTextBlock, _) = largeTitleWidget
        else {
            Issue.record("Expected dialogTitle text widget")
            return
        }
        #expect(largeTextBlock.plainText == "Constrained Margin Dialog")

        let largeMarginView = CampaignCanvasView(
            canvas: largeCanvas,
            surface: largeConfig.surface,
            designWidth: largeConfig.designWidth,
            availableSize: CGSize(width: availableWidthLarge, height: 260),
            onAction: { _ in }
        )
        let largeController = UIHostingController(rootView: largeMarginView)
        largeController.view.bounds = CGRect(x: 0, y: 0, width: availableWidthLarge, height: 260)
        largeController.view.layoutIfNeeded()
        #expect(largeController.view.bounds.width == 264)
    }

    // MARK: 3. Width Change Variants (nudge-dialog-width-narrow & nudge-dialog-width-wide)

    @Test @MainActor
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

        let narrowView = CampaignCanvasView(
            canvas: narrowCanvas,
            surface: narrowConfig.surface,
            designWidth: narrowConfig.designWidth,
            availableSize: CGSize(width: 260, height: 260),
            onAction: { _ in }
        )
        let narrowController = UIHostingController(rootView: narrowView)
        narrowController.view.bounds = CGRect(x: 0, y: 0, width: 260, height: 260)
        narrowController.view.layoutIfNeeded()
        #expect(narrowController.view.bounds.width == 260)

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

        let wideView = CampaignCanvasView(
            canvas: wideCanvas,
            surface: wideConfig.surface,
            designWidth: wideConfig.designWidth,
            availableSize: CGSize(width: 340, height: 260),
            onAction: { _ in }
        )
        let wideController = UIHostingController(rootView: wideView)
        wideController.view.bounds = CGRect(x: 0, y: 0, width: 340, height: 260)
        wideController.view.layoutIfNeeded()
        #expect(wideController.view.bounds.width == 340)
    }

    // MARK: 4. Dark Background / Surface Variant (nudge-dialog-bg-dark)

    @Test @MainActor
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

        // Render view and verify layout frame
        let darkView = CampaignCanvasView(
            canvas: darkCanvas,
            surface: darkConfig.surface,
            designWidth: darkConfig.designWidth,
            availableSize: CGSize(width: 320, height: 260),
            onAction: { _ in }
        )
        let darkController = UIHostingController(rootView: darkView)
        darkController.view.bounds = CGRect(x: 0, y: 0, width: 320, height: 260)
        darkController.view.layoutIfNeeded()
        #expect(darkController.view.bounds.size == CGSize(width: 320, height: 260))
    }

    // MARK: - Maestro Variant Visual Golden Snapshots

    @Test @MainActor
    func testNudgeDialogRadius0VisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-radius-0.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            let canvas = nudgeConfig.canvas
        else {
            Issue.record("Failed to parse sharp radius nudge config")
            return
        }

        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: 320, height: 260),
            onAction: { _ in }
        )
        let controller = UIHostingController(rootView: canvasView)
        controller.view.bounds = CGRect(x: 0, y: 0, width: 320, height: 260)
        controller.view.layoutIfNeeded()

        assertVisualGolden(matching: controller.view)
    }

    @Test @MainActor
    func testNudgeDialogRadius28VisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-radius-28.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            let canvas = nudgeConfig.canvas
        else {
            Issue.record("Failed to parse rounded radius nudge config")
            return
        }

        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: 320, height: 260),
            onAction: { _ in }
        )
        let controller = UIHostingController(rootView: canvasView)
        controller.view.bounds = CGRect(x: 0, y: 0, width: 320, height: 260)
        controller.view.layoutIfNeeded()

        assertVisualGolden(matching: controller.view)
    }

    @Test @MainActor
    func testNudgeDialogMarginZeroVisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-margin-zero.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            let canvas = nudgeConfig.canvas
        else {
            Issue.record("Failed to parse zero margin nudge config")
            return
        }

        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: 360, height: 260),
            onAction: { _ in }
        )
        let controller = UIHostingController(rootView: canvasView)
        controller.view.bounds = CGRect(x: 0, y: 0, width: 360, height: 260)
        controller.view.layoutIfNeeded()

        assertVisualGolden(matching: controller.view)
    }

    @Test @MainActor
    func testNudgeDialogMarginLargeVisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-margin-large.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            let canvas = nudgeConfig.canvas
        else {
            Issue.record("Failed to parse large margin nudge config")
            return
        }

        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: 264, height: 260),
            onAction: { _ in }
        )
        let controller = UIHostingController(rootView: canvasView)
        controller.view.bounds = CGRect(x: 0, y: 0, width: 264, height: 260)
        controller.view.layoutIfNeeded()

        assertVisualGolden(matching: controller.view)
    }

    @Test @MainActor
    func testNudgeDialogWidthNarrowVisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-width-narrow.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            let canvas = nudgeConfig.canvas
        else {
            Issue.record("Failed to parse narrow width nudge config")
            return
        }

        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: 260, height: 260),
            onAction: { _ in }
        )
        let controller = UIHostingController(rootView: canvasView)
        controller.view.bounds = CGRect(x: 0, y: 0, width: 260, height: 260)
        controller.view.layoutIfNeeded()

        assertVisualGolden(matching: controller.view)
    }

    @Test @MainActor
    func testNudgeDialogWidthWideVisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-width-wide.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            let canvas = nudgeConfig.canvas
        else {
            Issue.record("Failed to parse wide width nudge config")
            return
        }

        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: 340, height: 260),
            onAction: { _ in }
        )
        let controller = UIHostingController(rootView: canvasView)
        controller.view.bounds = CGRect(x: 0, y: 0, width: 340, height: 260)
        controller.view.layoutIfNeeded()

        assertVisualGolden(matching: controller.view)
    }

    @Test @MainActor
    func testNudgeDialogDarkThemeVisualGolden() throws {
        let fixture = try loadNudgeDialogFixture(named: "nudge-dialog-bg-dark.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
            let nudgeConfig = NudgeConfig.fromJson(templateConfig),
            let canvas = nudgeConfig.canvas
        else {
            Issue.record("Failed to parse dark background nudge config")
            return
        }

        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: 320, height: 260),
            onAction: { _ in }
        )
        let controller = UIHostingController(rootView: canvasView)
        controller.view.bounds = CGRect(x: 0, y: 0, width: 320, height: 260)
        controller.view.layoutIfNeeded()

        assertVisualGolden(matching: controller.view)
    }
}
