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
/// 2. Action execution flow with dismiss settlement (`LocalActionExecutor`)
/// 3. Drag gesture dismiss calculations (`shouldDismissBottomSheet`)
/// 4. Alternative bottom sheet configurations (close button, non-dismissible backdrop)
/// 5. Visual pixel snapshot golden diffing (`.image`)
extension NudgeComponentTests {
@Suite("Bottom sheet")
struct BottomSheet {

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

    @Test("parses the canonical bottom-sheet model and CTA contract", .tags(.contract, .smoke)) @MainActor
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

    // MARK: - 2. Action Execution & Dismiss Settlement

    @Test("executes dismiss locally and rejects non-local actions", .tags(.unit)) @MainActor
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

    // MARK: - 3. Drag Dismiss Pure Threshold Oracle

    @Test("dismisses only at the production drag threshold", .tags(.unit, .smoke))
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

    // MARK: - 4. Close Button Variant Contract

    @Test("parses the close-button bottom-sheet contract", .tags(.contract)) @MainActor
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

    // MARK: - 5. Visual Pixel Golden Snapshot

    @Test("matches the bottom-sheet visual golden", .tags(.golden)) @MainActor
    func testNudgeBottomSheetVisualImageGolden() throws {
        let fixture = try loadCompactBottomSheetFixture()
        guard let templateConfig = fixture["templateConfig"] as? [String: Any],
              let nudgeConfig = NudgeConfig.fromJson(templateConfig),
              nudgeConfig.canvas != nil else {
            Issue.record("Failed to parse canvas nudge config")
            return
        }

        let hostView = ComponentTestHost.makeRealBottomSheetHost(
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

    // MARK: - 6. Device Scrim & Anchoring Golden (.image on device)

    @Test("matches the production bottom-sheet device golden", .tags(.golden, .smoke)) @MainActor
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
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    // MARK: - 7. Safe Area Mode Variants (insetContent, insetSurface, none)

    @Test("matches the inset-content safe-area golden", .tags(.golden)) @MainActor
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
            record: isSnapshotRecordingEnabled ? .all : nil
        )

        let hostView = ComponentTestHost.makeRealBottomSheetHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer { ComponentTestHost.cleanupOverlayWindow(hostView) }
        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the inset-surface safe-area golden", .tags(.golden)) @MainActor
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
            record: isSnapshotRecordingEnabled ? .all : nil
        )

        let hostView = ComponentTestHost.makeRealBottomSheetHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer { ComponentTestHost.cleanupOverlayWindow(hostView) }
        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the edge-to-edge safe-area golden", .tags(.golden)) @MainActor
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
            record: isSnapshotRecordingEnabled ? .all : nil
        )

        let hostView = ComponentTestHost.makeRealBottomSheetHost(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
        )
        defer { ComponentTestHost.cleanupOverlayWindow(hostView) }
        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }
}
}
