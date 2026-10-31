import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// Pixel goldens for every Test Kit nudge fixture.
///
/// The arguments are read from `sdk_testing_fixtures/campaigns/<campaign>/`, so a fixture added to the
/// Test Kit gets a golden with no code change (record it with
/// `RECORD_SNAPSHOTS=true ./run-tests.sh nudge`). Each fixture is decoded by `NudgeConfig.fromJson`
/// and presented through the production `NudgeOverlayView`, like the hand-written goldens.
/// Fixtures the hand-written tests also cover get a golden here too, so every fixture has one under
/// its own name for the goldens reviewer.
@Suite("Test Kit fixture goldens", .serialized, .tags(.nudge))
struct NudgeGoldenTests {

    private static func fixtures(_ campaignType: String) -> [String] {
        FixtureLoader.fixtureNames(campaignType: campaignType)
    }

    @Test("matches the bottom-sheet fixture golden", .tags(.golden), arguments: fixtures("nudge_bottomsheet"))
    @MainActor
    func testBottomSheetFixtureGolden(fixture: String) throws {
        try assertFixtureGolden(campaignType: "nudge_bottomsheet", fixture: fixture)
    }

    @Test("matches the dialog fixture golden", .tags(.golden), arguments: fixtures("nudge_dialog"))
    @MainActor
    func testDialogFixtureGolden(fixture: String) throws {
        try assertFixtureGolden(campaignType: "nudge_dialog", fixture: fixture)
    }

    @Test("matches the full-screen fixture golden", .tags(.golden), arguments: fixtures("nudge_fullscreen"))
    @MainActor
    func testFullScreenFixtureGolden(fixture: String) throws {
        try assertFixtureGolden(campaignType: "nudge_fullscreen", fixture: fixture)
    }

    /// Snapshot file: `de_workspace/goldens/ios/<campaignType>/<fixture>.png`.
    @MainActor
    private func assertFixtureGolden(campaignType: String, fixture: String) throws {
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: campaignType, fileName: fixture),
            "Failed to load fixture \(campaignType)/\(fixture).json"
        )
        let templateConfig = try #require(json["templateConfig"] as? [String: Any], "Missing templateConfig")
        let nudgeConfig = try #require(try NudgeConfig.fromJson(templateConfig, designTokens: fixtureTokens(json)), "Fixture must decode to a nudge")

        // The package's test bundle has no host app, so the SDK's window lookup finds no window
        // and reads zero insets. Pin the golden device's screen and its notch / home-indicator
        // insets (47pt top, 34pt bottom) for the full-screen and dialog nudges, which lay out
        // against them on a device.
        let device = ViewImageConfig.engageGolden
        if nudgeConfig.surface.isFullScreen || nudgeConfig.surface.displayType == .dialog {
            let insets = device.safeArea
            activeFloaterWindowGeometryOverride = (
                CGRect(origin: .zero, size: device.size!),
                EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
            )
        }
        let hostView = ComponentTestHost.makeRealOverlayWindow(
            nudgeConfig: nudgeConfig,
            device: device,
            style: .striped
        )
        defer {
            activeFloaterWindowGeometryOverride = nil
            ComponentTestHost.cleanupOverlayWindow(hostView)
        }

        // Every pixel must match within the perceptual tolerance: 0.999 (used by the
        // hand-written goldens) lets ~3,800 pixels differ, enough to hide a short text change.
        assertSurfaceGolden(
            ComponentTestHost.settledImage(of: hostView),
            surface: campaignType,
            named: fixture,
            precision: 1.0,
            perceptualPrecision: 0.98
        )
    }
}
}
