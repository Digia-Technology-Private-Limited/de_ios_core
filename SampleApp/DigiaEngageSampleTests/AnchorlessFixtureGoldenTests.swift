import Foundation
import SnapshotTesting
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// Pixel goldens for every Test Kit anchorless guide fixture.
///
/// The arguments are read from `sdk_testing_fixtures/campaigns/anchorless/`, so a fixture added to the
/// Test Kit is covered with no code change (record it by running this target's tests with
/// `TEST_RUNNER_RECORD_SNAPSHOTS=true`; see `SampleApp/README.md`). Each fixture is decoded by
/// `CampaignModel.fromJson` for iOS, started on the SDK's guide orchestrator, and drawn by the
/// production `GuideOverlayView`. A golden shows the guide's first step.
///
/// The fixtures' crops are CDN images; every one is served as the Test Kit's `strawberry.jpg`, so a
/// golden shows how the picture is placed and clipped by the cutout.
@Suite("Test Kit anchorless fixture goldens", .serialized, .tags(.guide))
struct AnchorlessFixtureGoldenTests {

    /// Fixtures the SDK starts but never shows. Each is asserted to stay invisible, and fails once it
    /// draws; the bare host screen is also its golden, proving nothing was drawn, recorded as the
    /// sibling fixture goldens are.
    ///   - a target captured on another page;
    ///   - a target placed off screen.
    private static let notShown: Set<String> = [
        "anchorless_mismatch",
        "anchorless_out_of_bounds",
    ]

    private static let fixtures = FixtureLoader.fixtureNames(campaignType: "anchorless")

    @Test("matches the anchorless fixture golden", .tags(.golden), arguments: fixtures.filter { !notShown.contains($0) })
    @MainActor
    func testAnchorlessFixtureGolden(fixture: String) async throws {
        let showing = try show(fixture)
        defer { showing.end() }

        try #require(
            try await AnchorlessGuideHost.waitUntilDrawn(showing.window, differingFrom: showing.hostOnly),
            "The guide drew nothing"
        )
        // Exact within the perceptual tolerance, as the other fixture goldens.
        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: showing.window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: fixture,
            function: "testAnchorlessFixtureGolden"
        )
    }

    @Test("does not show a guide it cannot place", .tags(.component, .golden), arguments: fixtures.filter { notShown.contains($0) })
    @MainActor
    func testAnchorlessFixtureNotShown(fixture: String) async throws {
        let showing = try show(fixture)
        defer { showing.end() }

        // Past the crop's load and the failed step's drop.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(
            ComponentTestHost.renderImage(of: showing.window).pngData() == showing.hostOnly.pngData(),
            "\(fixture) now draws; remove it from `notShown` so the regular golden test covers it"
        )
        #expect(SDKInstance.shared.guideOrchestrator.state == nil, "\(fixture) is still showing")
        // The bare host screen is the golden too: it proves nothing was drawn.
        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: showing.window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: fixture,
            function: "testAnchorlessFixtureGolden"
        )
    }

    @MainActor
    private func show(_ fixture: String) throws -> AnchorlessGuideHost.Showing {
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: "anchorless", fileName: fixture),
            "Failed to load fixture anchorless/\(fixture).json"
        )
        let campaign = try #require(
            try CampaignModel.fromJson(json, designTokens: fixtureTokens(json), devicePlatform: "ios"),
            "Fixture must decode to a guide"
        )
        let workspace = try #require(FixtureLoader.workspaceURL(), "Test Kit not found")
        let strawberry = try Data(
            contentsOf: workspace.appendingPathComponent("testkit/mock-server/assets/strawberry.jpg"))
        return try AnchorlessGuideHost.show(campaign) { _ in strawberry }
    }
}
}
