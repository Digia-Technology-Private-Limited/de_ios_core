// tags: golden pip
import Testing

/// Every pip fixture (`sdk_testing_fixtures/campaigns/pip`) is delivered through the real SDK and shown by
/// `DigiaHost`. Each fixture gets two goldens: the collapsed window users see over the host app, and the
/// expanded state a real tap on the window opens.
///
/// Regenerate baselines after an intentional visual change:
///   RECORD_SNAPSHOTS=true ./run-tests.sh pip
@MainActor
@Suite("pip goldens", .serialized, .enabled(if: WorkspaceFixtures.skipReason == nil, "Test Kit missing"))
struct PipGoldenTests {
    @Test("pip", arguments: WorkspaceFixtures.campaigns(in: "pip"))
    func pip(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectOverlayGolden(fixture, surface: "pip")
    }
}
