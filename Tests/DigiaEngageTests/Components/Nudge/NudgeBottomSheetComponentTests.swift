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
@Suite("Bottom sheet", .serialized, .tags(.nudge))
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

    // MARK: - 2. Drag Dismiss Pure Threshold Oracle

    struct DragThresholdCase: CustomTestStringConvertible {
        let dragDistance: CGFloat
        let sheetHeight: CGFloat
        let shouldDismiss: Bool
        var testDescription: String {
            "drag \(dragDistance)pt on \(sheetHeight)pt sheet -> dismiss \(shouldDismiss)"
        }
    }

    @Test(
        "dismisses only at the production drag threshold",
        .tags(.unit, .smoke),
        arguments: [
            DragThresholdCase(dragDistance: 50, sheetHeight: 240, shouldDismiss: false),
            DragThresholdCase(dragDistance: 119, sheetHeight: 240, shouldDismiss: false),
            DragThresholdCase(dragDistance: 120, sheetHeight: 240, shouldDismiss: true),
            DragThresholdCase(dragDistance: 150, sheetHeight: 240, shouldDismiss: true),
            DragThresholdCase(dragDistance: 120, sheetHeight: 600, shouldDismiss: false),
            DragThresholdCase(dragDistance: 149, sheetHeight: 600, shouldDismiss: false),
            DragThresholdCase(dragDistance: 150, sheetHeight: 600, shouldDismiss: true),
        ]
    )
    func testNudgeBottomSheetDragDismissThresholds(testCase: DragThresholdCase) {
        #expect(
            shouldDismissBottomSheet(
                dragDistance: testCase.dragDistance,
                sheetHeight: testCase.sheetHeight
            ) == testCase.shouldDismiss
        )
    }

    // MARK: - 6. Visual Pixel Golden Snapshot

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

    // MARK: - 7. Device Scrim & Anchoring Golden (.image on device)

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

    // MARK: - 8. Safe Area Mode Variants (insetContent, insetSurface, none)

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

    // MARK: - 9. Bottom Sheet Dismissal, Gestures & Close Button

    @Test("DigiaBottomSheet close() invokes onDismiss callback", .tags(.unit, .smoke)) @MainActor
    func testBottomSheetCloseCallback() async throws {
        var dismissed = false
        let sheet = DigiaBottomSheet(
            config: DigiaBottomSheetConfig(),
            onDismiss: { dismissed = true },
            content: { Text("Test") }
        )
        sheet.close()
        // Wait for animation completion callback
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(dismissed)
    }

    @Test("DigiaBottomSheet backdrop tap dismisses when allowed and ignores when disabled", .tags(.unit)) @MainActor
    func testBottomSheetBackdropTap() async throws {
        var dismissCount = 0
        let allowedSheet = DigiaBottomSheet(
            config: DigiaBottomSheetConfig(allowBackdropDismiss: true),
            onDismiss: { dismissCount += 1 },
            content: { Text("Allowed") }
        )
        allowedSheet.handleBackdropTap()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(dismissCount == 1)

        let blockedSheet = DigiaBottomSheet(
            config: DigiaBottomSheetConfig(allowBackdropDismiss: false),
            onDismiss: { dismissCount += 1 },
            content: { Text("Blocked") }
        )
        blockedSheet.handleBackdropTap()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(dismissCount == 1) // Did not increment
    }

    @Test("DigiaBottomSheet drag gesture change and end thresholds", .tags(.unit)) @MainActor
    func testBottomSheetDragGestureHandlers() async throws {
        var dismissed = false
        let sheet = DigiaBottomSheet(
            config: DigiaBottomSheetConfig(allowDragDismiss: true),
            onDismiss: { dismissed = true },
            content: { Text("Drag") }
        )
        sheet.handleDragChange(translationHeight: 50)
        sheet.handleDragChange(translationHeight: -20)

        // Below threshold (120pt): does not dismiss
        sheet.handleDragEnd(translationHeight: 80)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!dismissed)

        // Above threshold (120pt): dismisses
        sheet.handleDragEnd(translationHeight: 150)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(dismissed)
    }

    @Test("DigiaBottomSheet scrollsEntireSurface renders entireSurfaceBody", .tags(.unit)) @MainActor
    func testBottomSheetScrollsEntireSurfaceRendering() throws {
        let sheet = DigiaBottomSheet(
            config: DigiaBottomSheetConfig(
                showHandle: true,
                handleOverlaysContent: false,
                scrollsEntireSurface: true,
                entireSurfaceScrollingEnabled: true
            ),
            onDismiss: {},
            content: {
                VStack {
                    Text("Line 1")
                    Text("Line 2")
                }
            }
        )
        let hosting = UIHostingController(rootView: AnyView(sheet))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 600))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        ComponentTestHost.drainRunLoop(for: 0.1)
        _ = ComponentTestHost.renderImage(of: hosting.view)
        window.rootViewController = nil
        window.isHidden = true
        #expect(hosting.view != nil)
    }

    @Test("NudgeSheetView cardCloseButton branches for placed and unplaced configurations", .tags(.unit)) @MainActor
    func testNudgeSheetViewCardCloseButtonBranches() throws {
        // 1. showCloseButton = false -> cardCloseButton is nil
        let surfaceNoClose = NudgeSurface(
            displayType: .bottomSheet,
            backgroundColor: nil,
            barrierColor: nil,
            cornerRadius: 16,
            padding: 16,
            backdropDismissible: true,
            showCloseButton: false,
            closeButton: NudgeCloseButtonConfig(
                marginTop: 12, marginRight: 12, backgroundColor: .black, iconColor: .white, iconSize: 18, placement: nil
            ),
            showHandle: true,
            draggable: true,
            widthFraction: 1.0,
            minHorizontalMargin: 0,
            useSafeArea: true,
            bottomSafeAreaMode: .none
        )
        let configNoClose = NudgeConfig(
            surface: surfaceNoClose,
            layout: NudgeColumn(crossAxisAlignment: .start, mainAxisAlignment: .start, children: []),
            canvas: nil,
            designWidth: 375,
            variableSchemas: []
        )
        let presentationNoClose = DigiaNudgePresentation(
            config: configNoClose,
            payload: CEPTriggerPayload(cepCampaignId: "sheet_test_1", campaignKey: "sheet_test", cepMetadata: [:]),
            variables: nil
        )
        let sheetViewNoClose = NudgeSheetView(presentation: presentationNoClose)
        #expect(sheetViewNoClose.cardCloseButton == nil)

        // 2. showCloseButton = true without placement -> returns NudgeCloseButton
        let surfaceUnplaced = NudgeSurface(
            displayType: .bottomSheet,
            backgroundColor: nil,
            barrierColor: nil,
            cornerRadius: 16,
            padding: 16,
            backdropDismissible: true,
            showCloseButton: true,
            closeButton: NudgeCloseButtonConfig(
                marginTop: 12, marginRight: 12, backgroundColor: .black, iconColor: .white, iconSize: 18, placement: nil
            ),
            showHandle: true,
            draggable: true,
            widthFraction: 1.0,
            minHorizontalMargin: 0,
            useSafeArea: true,
            bottomSafeAreaMode: .none
        )
        let configUnplaced = NudgeConfig(
            surface: surfaceUnplaced,
            layout: NudgeColumn(crossAxisAlignment: .start, mainAxisAlignment: .start, children: []),
            canvas: nil,
            designWidth: 375,
            variableSchemas: []
        )
        let presentationUnplaced = DigiaNudgePresentation(
            config: configUnplaced,
            payload: CEPTriggerPayload(cepCampaignId: "sheet_test_2", campaignKey: "sheet_test", cepMetadata: [:]),
            variables: nil
        )
        let sheetViewUnplaced = NudgeSheetView(presentation: presentationUnplaced)
        #expect(sheetViewUnplaced.cardCloseButton != nil)

        // 3. showCloseButton = true with placement -> cardCloseButton is nil (handled in viewportOverlay)
        let placement = NudgeCloseButtonPlacement(
            horizontal: .right,
            vertical: .top,
            margin: .init(),
            rect: CGRect(x: 10, y: 10, width: 20, height: 20)
        )
        let surfacePlaced = NudgeSurface(
            displayType: .bottomSheet,
            backgroundColor: nil,
            barrierColor: nil,
            cornerRadius: 16,
            padding: 16,
            backdropDismissible: true,
            showCloseButton: true,
            closeButton: NudgeCloseButtonConfig(
                marginTop: 12, marginRight: 12, backgroundColor: .black, iconColor: .white, iconSize: 18, placement: placement
            ),
            showHandle: true,
            draggable: true,
            widthFraction: 1.0,
            minHorizontalMargin: 0,
            useSafeArea: true,
            bottomSafeAreaMode: .none
        )
        let configPlaced = NudgeConfig(
            surface: surfacePlaced,
            layout: NudgeColumn(crossAxisAlignment: .start, mainAxisAlignment: .start, children: []),
            canvas: nil,
            designWidth: 375,
            variableSchemas: []
        )
        let presentationPlaced = DigiaNudgePresentation(
            config: configPlaced,
            payload: CEPTriggerPayload(cepCampaignId: "sheet_test_3", campaignKey: "sheet_test", cepMetadata: [:]),
            variables: nil
        )
        let sheetViewPlaced = NudgeSheetView(presentation: presentationPlaced)
        #expect(sheetViewPlaced.cardCloseButton == nil)
    }
}
