// tags: golden floater
import Testing

/// Every floater fixture (`sdk_testing_fixtures/campaigns/floater`) is delivered through the real SDK and shown by
/// `DigiaHost`. Each fixture gets two goldens: the collapsed window users see over the host app, and the
/// expanded state a real tap on the window opens.
///
/// Regenerate baselines after an intentional visual change:
///   RECORD_SNAPSHOTS=true ./run-tests.sh floater
@MainActor
@Suite("floater goldens", .serialized, .enabled(if: WorkspaceFixtures.skipReason == nil, "Test Kit missing"))
struct FloaterGoldenTests {
    @Test("floater", arguments: WorkspaceFixtures.campaigns(in: "floater"))
    func floater(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectOverlayGolden(fixture, surface: "floater")
    }
}
