// tags: golden canvas
import Testing

/// Every inline Canvas fixture (`sdk_testing_fixtures/campaigns/<canvas|inline_canvas>`) is delivered by the
/// CEP and drawn by `DigiaSlot`, the view host apps place, so each golden is the card users see inside the host
/// screen. Images and Lottie files are served from the Test Kit's mock-server directory.
///
/// Regenerate baselines after an intentional visual change:
///   RECORD_SNAPSHOTS=true ./run-tests.sh canvas
@MainActor
@Suite("canvas goldens", .serialized, .enabled(if: WorkspaceFixtures.skipReason == nil, "Test Kit missing"))
struct CanvasGoldenTests {
    /// A picture on a host the Test Kit does not serve is unreachable here, so its failure state is drawn.
    private static let unreachableForeignMedia = StubBackend.Options(foreignImagesAsStandIn: false)

    @Test("canvas", arguments: WorkspaceFixtures.campaigns(in: "canvas"))
    func canvas(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectFixtureGolden(fixture, surface: "canvas", host: .slot(fixture.slotKey ?? "home_banner"), backend: Self.unreachableForeignMedia)
    }

    @Test("inline_canvas", arguments: WorkspaceFixtures.campaigns(in: "inline_canvas"))
    func inlineCanvas(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectFixtureGolden(fixture, surface: "inline_canvas", host: .slot(fixture.slotKey ?? "home_banner"), backend: Self.unreachableForeignMedia)
    }
}
