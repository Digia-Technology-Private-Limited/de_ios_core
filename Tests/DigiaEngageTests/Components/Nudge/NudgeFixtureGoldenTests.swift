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
struct NudgeFixtureGoldenTests {

    private static func fixtures(_ campaignType: String) -> [String] {
        FixtureLoader.fixtureNames(campaignType: campaignType)
    }

    @Test("matches the bottom-sheet fixture golden", .tags(.golden), arguments: fixtures("nudge_bottomsheet"))
    @MainActor
    func testBottomSheetFixtureGolden(fixture: String) throws {
        try assertFixtureGolden(campaignType: "nudge_bottomsheet", fixture: fixture, test: "testBottomSheetFixtureGolden")
    }

    @Test("matches the dialog fixture golden", .tags(.golden), arguments: fixtures("nudge_dialog"))
    @MainActor
    func testDialogFixtureGolden(fixture: String) throws {
        try assertFixtureGolden(campaignType: "nudge_dialog", fixture: fixture, test: "testDialogFixtureGolden")
    }

    @Test("matches the full-screen fixture golden", .tags(.golden), arguments: fixtures("nudge_fullscreen"))
    @MainActor
    func testFullScreenFixtureGolden(fixture: String) throws {
        try assertFixtureGolden(campaignType: "nudge_fullscreen", fixture: fixture, test: "testFullScreenFixtureGolden")
    }

    /// Snapshot file: `de_workspace/goldens/ios/NudgeFixtureGoldenTests/<test>.<fixture>.png`.
    @MainActor
    private func assertFixtureGolden(campaignType: String, fixture: String, test: StaticString) throws {
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: campaignType, fileName: fixture),
            "Failed to load fixture \(campaignType)/\(fixture).json"
        )
        let templateConfig = try #require(json["templateConfig"] as? [String: Any], "Missing templateConfig")
        let nudgeConfig = try #require(try NudgeConfig.fromJson(templateConfig, designTokens: fixtureTokens(json)), "Fixture must decode to a nudge")

        // Full-screen and dialog nudges lay out against the host's safe area
        // on a device, like every SlotHostScreen suite already assumes from
        // the same ViewImageConfig (47pt notch, 34pt home indicator). Give the
        // host controller those insets; the SDK's own safe-area handling is
        // what is exercised, with no per-fixture adjustment.
        let device = ViewImageConfig.engageGolden
        let usesHostSafeArea =
            nudgeConfig.surface.isFullScreen || nudgeConfig.surface.displayType == .dialog
        let hostView = ComponentTestHost.makeRealOverlayWindow(
            nudgeConfig: nudgeConfig,
            device: device,
            style: .striped,
            hostSafeArea: usesHostSafeArea ? device.safeArea : .zero
        )
        defer { ComponentTestHost.cleanupOverlayWindow(hostView) }

        // Every pixel must match within the perceptual tolerance: 0.999 (used by the
        // hand-written goldens) lets ~3,800 pixels differ, enough to hide a short text change.
        assertVisualGolden(
            matching: settledImage(of: hostView),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: fixture,
            function: test
        )
    }

    /// The first presentation in a run can still be animating after the host's fixed wait, which
    /// made its golden flaky; render until two frames 0.1s apart are identical (at most 2s).
    @MainActor
    private func settledImage(of view: UIView) -> UIImage {
        var image = ComponentTestHost.renderImage(of: view)
        for _ in 0..<20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let next = ComponentTestHost.renderImage(of: view)
            if next.pngData() == image.pngData() { return next }
            image = next
        }
        return image
    }
}
}
