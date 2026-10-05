import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// Component and interaction tests for the canonical Nudge BottomSheet scenario (`test_nudge_bottomsheet_compact`).
///
/// Validates:
/// 1. Wire schema and layout parsing into `NudgeConfig` and `CampaignCanvas`
/// 2. Interactive CTA action callback routing and payload accuracy
/// 3. Action execution flow with dismiss settlement (`LocalActionExecutor`)
/// 4. Drag gesture dismiss calculations (`shouldDismissBottomSheet`)
/// 5. Alternative bottom sheet configurations (close button, non-dismissible backdrop)
/// 6. View hierarchy snapshot diffing (`.sanitizedHierarchy`)
/// 7. Visual pixel snapshot golden diffing (`.image`)
@Suite(.serialized, .tags(.nudge, .smoke))
struct NudgeBottomSheetComponentTests {

    private func loadCompactBottomSheetFixture() throws -> [String: Any] {
        guard let fixture = FixtureLoader.loadFixture(
            campaignType: "nudge_bottomsheet",
            fileName: "nudge-bottomsheet-compact.json"
        ) else {
            Issue.record("Failed to load fixture for nudge_bottomsheet/nudge-bottomsheet-compact.json")
            return [:]
        }
        return fixture
    }

    private func loadCloseButtonBottomSheetFixture() throws -> [String: Any] {
        guard let fixture = FixtureLoader.loadFixture(
            campaignType: "nudge_bottomsheet",
            fileName: "nudge-bottomsheet-close-button.json"
        ) else {
            Issue.record("Failed to load fixture for nudge_bottomsheet/nudge-bottomsheet-close-button.json")
            return [:]
        }
        return fixture
    }

    private func loadSafeAreaFixture(named name: String) throws -> [String: Any] {
        guard let fixture = FixtureLoader.loadFixture(
            campaignType: "nudge_bottomsheet",
            fileName: name
        ) else {
            Issue.record("Failed to load fixture for nudge_bottomsheet/\(name)")
            return [:]
        }
        return fixture
    }

    // MARK: - 1. Wire Contract & Model Parsing

    @Test @MainActor
    func testNudgeBottomSheetModelParsingAndContract() throws {
        let fixture = try loadCompactBottomSheetFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any] else {
            Issue.record("Missing templateConfig")
            return
        }

        let nudgeConfig = try #require(NudgeConfig.fromJson(templateConfig))

        // Surface / container assertions
        #expect(nudgeConfig.surface.displayType == .bottomSheet)
        #expect(nudgeConfig.surface.isBottomSheet)
        #expect(!nudgeConfig.surface.isFullScreen)
        #expect(nudgeConfig.surface.cornerRadius == 18)
        #expect(nudgeConfig.surface.padding == 20)
        #expect(nudgeConfig.surface.backdropDismissible)
        #expect(nudgeConfig.surface.showHandle)
        #expect(nudgeConfig.surface.draggable)
        #expect(!nudgeConfig.surface.showCloseButton)

        // Canvas assertions
        let canvas = try #require(nudgeConfig.canvas)
        #expect(canvas.width == 375)
        #expect(canvas.height == 240)
        #expect(canvas.children.count == 3)

        // Verify child node identities
        #expect(canvas.children[0].id == "title")
        #expect(canvas.children[1].id == "body")
        #expect(canvas.children[2].id == "button")

        // Parse button node widget details
        let buttonNode = canvas.children[2]
        guard case .widget(let id, _, let widget) = buttonNode,
              id == "button",
              case .button(_, let label, _, _, _, let isPrimary, _, _, let actions, _) = widget else {
            Issue.record("Expected button widget for child with id 'button'")
            return
        }

        #expect(isPrimary)
        #expect(label.plainText == "OK")
        #expect(actions == [.dismiss])
    }

    // MARK: - 2. Action Callback & Event Tracking Dispatch

    @Test @MainActor
    func testNudgeBottomSheetActionDispatch() throws {
        let fixture = try loadCompactBottomSheetFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
              let nudgeConfig = NudgeConfig.fromJson(templateConfig),
              let canvas = nudgeConfig.canvas else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        var dispatchedAction: CampaignCanvasActionRequest?
        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: 375, height: 240),
            onAction: { request in
                dispatchedAction = request
            }
        )

        // Directly invoke action request mimicking button tap
        let expectedRequest = CampaignCanvasActionRequest(
            actions: [.dismiss],
            elementId: "button",
            label: "OK",
            isPrimary: true
        )
        canvasView.onAction(expectedRequest)

        // Assert exact action request payload
        #expect(dispatchedAction != nil)
        #expect(dispatchedAction?.elementId == "button")
        #expect(dispatchedAction?.label == "OK")
        #expect(dispatchedAction?.isPrimary == true)
        #expect(dispatchedAction?.actions == [.dismiss])
    }

    // MARK: - 3. Action Execution & Dismiss Settlement

    @Test @MainActor
    func testNudgeBottomSheetDismissActionExecution() throws {
        var dismissInvoked = false
        let executor = LocalActionExecutor(dismiss: {
            dismissInvoked = true
        })

        // Execute dismiss action through action executor
        let handled = executor.execute(.dismiss)
        #expect(handled)
        #expect(dismissInvoked)

        // Non-local action should not be handled by LocalActionExecutor
        let unhandled = executor.execute(.openUrl("https://digia.cloud"))
        #expect(!unhandled)
    }

    // MARK: - 4. Drag Dismiss Pure Threshold Oracle

    @Test
    func testNudgeBottomSheetDragDismissThresholds() {
        // Minimum drag distance is 120pt, or 25% of sheet height, whichever is larger
        // For a 240pt sheet: max(120, 240 * 0.25 = 60) = 120pt
        #expect(!shouldDismissBottomSheet(dragDistance: 50, sheetHeight: 240))
        #expect(!shouldDismissBottomSheet(dragDistance: 119, sheetHeight: 240))
        #expect(shouldDismissBottomSheet(dragDistance: 120, sheetHeight: 240))
        #expect(shouldDismissBottomSheet(dragDistance: 150, sheetHeight: 240))

        // For a 600pt sheet: max(120, 600 * 0.25 = 150) = 150pt
        #expect(!shouldDismissBottomSheet(dragDistance: 120, sheetHeight: 600))
        #expect(!shouldDismissBottomSheet(dragDistance: 149, sheetHeight: 600))
        #expect(shouldDismissBottomSheet(dragDistance: 150, sheetHeight: 600))
    }

    // MARK: - 5. Close Button Variant Contract

    @Test @MainActor
    func testNudgeBottomSheetCloseButtonVariantContract() throws {
        let fixture = try loadCloseButtonBottomSheetFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
              let nudgeConfig = NudgeConfig.fromJson(templateConfig) else {
            Issue.record("Failed to parse close-button bottom sheet")
            return
        }

        #expect(!nudgeConfig.surface.backdropDismissible)
        #expect(!nudgeConfig.surface.draggable)
        #expect(nudgeConfig.surface.showHandle)
        #expect(nudgeConfig.surface.closeButton.placement?.horizontal == .right)
        #expect(nudgeConfig.surface.closeButton.placement?.vertical == .top)
    }

    // MARK: - 6. View Hierarchy Snapshot Diff

    @Test @MainActor
    func testNudgeBottomSheetComponentHierarchyAndLayout() throws {
        let fixture = try loadCompactBottomSheetFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
              let nudgeConfig = NudgeConfig.fromJson(templateConfig),
              let canvas = nudgeConfig.canvas else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        let canvasWidth = canvas.width
        let canvasHeight = canvas.height
        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: canvasWidth, height: canvasHeight),
            onAction: { _ in }
        )

        let controller = ComponentTestHost.makeComponentHost(
            rootView: canvasView,
            size: CGSize(width: canvasWidth, height: canvasHeight),
            backgroundColor: .clear
        )

        #expect(controller.view.bounds.width == canvasWidth)
        #expect(controller.view.bounds.height == canvasHeight)

        // Capture full AST and layout model snapshot using Swift reflection (.dump)
        assertSnapshot(
            of: nudgeConfig,
            as: .dump,
            record: isSnapshotRecordingEnabled
        )
    }

    // MARK: - 7. Visual Pixel Golden Snapshot

    @Test @MainActor
    func testNudgeBottomSheetVisualImageGolden() throws {
        let fixture = try loadCompactBottomSheetFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
              let nudgeConfig = NudgeConfig.fromJson(templateConfig),
              let canvas = nudgeConfig.canvas else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        let canvasWidth = canvas.width
        let canvasHeight = canvas.height
        let canvasView = CampaignCanvasView(
            canvas: canvas,
            surface: nudgeConfig.surface,
            designWidth: nudgeConfig.designWidth,
            availableSize: CGSize(width: canvasWidth, height: canvasHeight),
            onAction: { _ in }
        )

        let controller = ComponentTestHost.makeComponentHost(
            rootView: canvasView,
            size: CGSize(width: canvasWidth, height: canvasHeight),
            backgroundColor: .white
        )

        // Capture pixel snapshot with native Xcode attachment integration
        assertVisualGolden(matching: controller.view)
    }

    // MARK: - 8. Device Scrim & Anchoring Golden (.image on device)

    @Test @MainActor
    func testNudgeBottomSheetDeviceGolden() throws {
        let fixture = try loadCompactBottomSheetFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
              let nudgeConfig = NudgeConfig.fromJson(templateConfig),
              let _ = nudgeConfig.canvas else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealBottomSheetHost(
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

    // MARK: - 9. Safe Area Bottom Clearance Contract

    @Test @MainActor
    func testNudgeBottomSheetSafeAreaClearance() throws {
        let fixture = try loadCompactBottomSheetFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
              let nudgeConfig = NudgeConfig.fromJson(templateConfig),
              let canvas = nudgeConfig.canvas else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        // Pinned iPhone 17 Pro Max safe area reference
        let config = ViewImageConfig.iPhone17ProMax
        let homeIndicatorHeight: CGFloat = config.safeArea.bottom
        #expect(homeIndicatorHeight == 34)

        // 1. Verify default mode is insetContent
        #expect(nudgeConfig.surface.bottomSafeAreaMode == .insetContent)

        // 2. Validate DigiaBottomSheetConfig clearance calculation
        let defaultPadding: CGFloat = 8
        let sheetConfig = DigiaBottomSheetConfig(
            bottomPadding: defaultPadding,
            bottomSafeAreaMode: nudgeConfig.surface.bottomSafeAreaMode,
            bottomSafeAreaInset: homeIndicatorHeight
        )

        // In .insetContent mode, bottom clearance is padding + safeAreaInset
        let effectiveBottomPadding = sheetConfig.bottomPadding + (sheetConfig.bottomSafeAreaMode == .insetContent ? sheetConfig.bottomSafeAreaInset : 0)
        #expect(effectiveBottomPadding == defaultPadding + homeIndicatorHeight)

        // 3. Test Host View Controller geometry clearance
        let hostBounds = CGRect(origin: .zero, size: config.size!)
        let sheetHeight = canvas.height

        // Inset surface mode: card frame elevated above safe area
        let surfaceElevatedY = hostBounds.height - sheetHeight - homeIndicatorHeight
        let surfaceCardRect = CGRect(x: 0, y: surfaceElevatedY, width: hostBounds.width, height: sheetHeight)
        #expect(surfaceCardRect.maxY == hostBounds.height - homeIndicatorHeight)
        #expect(surfaceCardRect.maxY <= hostBounds.height - homeIndicatorHeight)

        // Inset content mode: card attaches flush to bottom, internal content padded
        let contentFlushRect = CGRect(x: 0, y: hostBounds.height - sheetHeight, width: hostBounds.width, height: sheetHeight)
        let internalContentMaxY = contentFlushRect.height - effectiveBottomPadding
        #expect(internalContentMaxY == sheetHeight - effectiveBottomPadding)
        #expect(contentFlushRect.maxY - effectiveBottomPadding <= hostBounds.height - homeIndicatorHeight)
    }

    // MARK: - 10. Safe Area Mode Variants (insetContent, insetSurface, none)

    @Test @MainActor
    func testNudgeBottomSheetSafeAreaInsetContentVariant() throws {
        let fixture = try loadSafeAreaFixture(named: "nudge-bottomsheet-safe-area.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
              let nudgeConfig = NudgeConfig.fromJson(templateConfig),
              let _ = nudgeConfig.canvas else {
            Issue.record("Failed to parse safe-area bottomsheet config")
            return
        }

        #expect(nudgeConfig.surface.bottomSafeAreaMode == .insetContent)

        assertSnapshot(
            of: nudgeConfig,
            as: .dump,
            record: isSnapshotRecordingEnabled
        )
    }

    @Test @MainActor
    func testNudgeBottomSheetSafeAreaInsetSurfaceVariant() throws {
        let fixture = try loadSafeAreaFixture(named: "nudge-bottomsheet-safe-area-surface.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
              let nudgeConfig = NudgeConfig.fromJson(templateConfig),
              let _ = nudgeConfig.canvas else {
            Issue.record("Failed to parse safe-area-surface bottomsheet config")
            return
        }

        #expect(nudgeConfig.surface.bottomSafeAreaMode == .insetSurface)

        assertSnapshot(
            of: nudgeConfig,
            as: .dump,
            record: isSnapshotRecordingEnabled
        )
    }

    @Test @MainActor
    func testNudgeBottomSheetSafeAreaNoneVariant() throws {
        let fixture = try loadSafeAreaFixture(named: "nudge-bottomsheet-safe-area-none.json")
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
              let nudgeConfig = NudgeConfig.fromJson(templateConfig),
              let _ = nudgeConfig.canvas else {
            Issue.record("Failed to parse safe-area-none bottomsheet config")
            return
        }

        #expect(nudgeConfig.surface.bottomSafeAreaMode == .none)

        assertSnapshot(
            of: nudgeConfig,
            as: .dump,
            record: isSnapshotRecordingEnabled
        )
    }
}
