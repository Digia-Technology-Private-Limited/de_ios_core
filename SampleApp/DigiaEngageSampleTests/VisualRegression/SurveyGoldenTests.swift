// tags: golden survey
import Testing

/// Every survey fixture (`sdk_testing_fixtures/campaigns/survey`) is delivered through the real SDK and shown
/// by `DigiaHost`'s survey renderer, so each golden is the survey's first scene as users see it, in its
/// dialog or bottom sheet.
///
/// Regenerate baselines after an intentional visual change:
///   RECORD_SNAPSHOTS=true ./run-tests.sh survey
@MainActor
@Suite("survey goldens", .serialized, .enabled(if: WorkspaceFixtures.skipReason == nil, "Test Kit missing"))
struct SurveyGoldenTests {
    @Test("survey", arguments: WorkspaceFixtures.campaigns(in: "survey"))
    func survey(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectFixtureGolden(fixture, surface: "survey")
    }
}
