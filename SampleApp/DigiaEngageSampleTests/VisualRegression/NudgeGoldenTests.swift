// tags: golden nudge
import Testing

/// Every campaign fixture in `sdk_testing_fixtures/campaigns/<nudge_*>` is delivered through the real SDK
/// and shown by the real `DigiaHost`, so each golden is what users see:
///   - bottom sheet, dialog, full screen
///
/// Regenerate baselines after an intentional visual change:
///   RECORD_SNAPSHOTS=true ./run-tests.sh nudge
@MainActor
@Suite("nudge goldens", .serialized, .enabled(if: WorkspaceFixtures.skipReason == nil, "Test Kit missing"))
struct NudgeGoldenTests {
    @Test("nudge_bottomsheet", arguments: WorkspaceFixtures.campaigns(in: "nudge_bottomsheet"))
    func bottomSheet(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectFixtureGolden(fixture, surface: "nudge_bottomsheet")
    }

    @Test("nudge_dialog", arguments: WorkspaceFixtures.campaigns(in: "nudge_dialog"))
    func dialog(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectFixtureGolden(fixture, surface: "nudge_dialog")
    }

    @Test("nudge_fullscreen", arguments: WorkspaceFixtures.campaigns(in: "nudge_fullscreen"))
    func fullscreen(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectFixtureGolden(fixture, surface: "nudge_fullscreen")
    }
}
