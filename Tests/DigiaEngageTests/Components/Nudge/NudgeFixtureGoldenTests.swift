import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// Pixel goldens for every Test Kit nudge fixture that has no hand-written golden test.
///
/// The arguments are read from `testkit/campaigns/<campaign>/fixtures/`, so a fixture added to the
/// Test Kit gets a golden with no code change (record it with
/// `RECORD_SNAPSHOTS=true ./run-tests.sh nudge`). Each fixture is decoded by `NudgeConfig.fromJson`
/// and presented through the production `NudgeOverlayView`, like the hand-written goldens.
/// Fixtures those tests already cover are left out so no fixture has two goldens.
@Suite("Test Kit fixture goldens", .serialized, .tags(.nudge))
struct NudgeFixtureGoldenTests {

    /// Fixtures with a golden in `NudgeBottomSheetComponentTests` / `NudgeDialogComponentTests`.
    private static let coveredElsewhere: Set<String> = [
        "nudge-bottomsheet-compact",
        "nudge-bottomsheet-safe-area",
        "nudge-bottomsheet-safe-area-surface",
        "nudge-bottomsheet-safe-area-none",
        "nudge-dialog",
        "nudge-dialog-radius-0",
        "nudge-dialog-radius-28",
        "nudge-dialog-margin-zero",
        "nudge-dialog-margin-large",
        "nudge-dialog-width-narrow",
        "nudge-dialog-width-wide",
        "nudge-dialog-bg-dark",
    ]

    private static func fixtures(_ campaignType: String) -> [String] {
        FixtureLoader.fixtureNames(campaignType: campaignType).filter { !coveredElsewhere.contains($0) }
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

    /// Snapshot file: `__Snapshots__/NudgeFixtureGoldenTests/<test>.<fixture>.png`.
    @MainActor
    private func assertFixtureGolden(campaignType: String, fixture: String, test: StaticString) throws {
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: campaignType, fileName: fixture),
            "Failed to load fixture \(campaignType)/\(fixture).json"
        )
        let templateConfig = try #require(json["templateConfig"] as? [String: Any], "Missing templateConfig")
        let nudgeConfig = try #require(NudgeConfig.fromJson(templateConfig), "Fixture must decode to a nudge")

        let hostView = ComponentTestHost.makeRealOverlayWindow(
            nudgeConfig: nudgeConfig,
            device: .iPhone17ProMax,
            style: .solid(.systemBackground)
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
