// tags: golden inline
import Testing

/// Every inline fixture (`sdk_testing_fixtures/campaigns/<inline_*>`) is delivered by the CEP and drawn by
/// `DigiaSlot`, so each golden is the card users see inside the host screen:
///   - inline_banner, inline_carousel, inline_story, inline_timer
///
/// The fixtures' picsum and CDN images are served as the Test Kit's `strawberry.jpg`. Timers run on a
/// server clock that reads 2 d 03:45:13 before their deadline when the frame is taken.
///
/// Regenerate baselines after an intentional visual change:
///   RECORD_SNAPSHOTS=true ./run-tests.sh inline
@MainActor
@Suite("inline goldens", .serialized, .enabled(if: WorkspaceFixtures.skipReason == nil, "Test Kit missing"))
struct InlineGoldenTests {
    @Test("inline_banner", arguments: WorkspaceFixtures.campaigns(in: "inline_banner"))
    func banner(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectFixtureGolden(fixture, surface: "inline_banner", host: .slot(fixture.slotKey ?? ""))
    }

    @Test("inline_carousel", arguments: WorkspaceFixtures.campaigns(in: "inline_carousel"))
    func carousel(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectFixtureGolden(fixture, surface: "inline_carousel", host: .slot(fixture.slotKey ?? ""))
    }

    @Test("inline_story", arguments: WorkspaceFixtures.campaigns(in: "inline_story"))
    func story(_ fixture: WorkspaceFixtures.Campaign) async throws {
        try await GoldenHarness.expectFixtureGolden(fixture, surface: "inline_story", host: .slot(fixture.slotKey ?? ""))
    }

    @Test("inline_timer", arguments: WorkspaceFixtures.campaigns(in: "inline_timer"))
    func timer(_ fixture: WorkspaceFixtures.Campaign) async throws {
        var backend = StubBackend.Options()
        backend.serverTimeMs = GoldenHarness.timerServerTimeMs(expectedElapsed: 1.8)
        let show = { @MainActor in
            try await GoldenHarness.expectFixtureGolden(fixture, surface: "inline_timer", host: .slot(fixture.slotKey ?? ""), backend: backend, sendFallbackVariables: true)
        }
        // Parity gap, reported rather than recorded around: the fixture's deadline token is "  sale_ends  ".
        // Flutter trims a `fromVariable` token (`inline_canvas_config.dart`); iOS's `nonBlankString` returns it
        // untrimmed, so the variable never resolves and the SDK drops a campaign Flutter shows. Remove this
        // wrapper once `StatefulTimerConfig` trims the token.
        if fixture.name == "inline_timer_variable_instant_formats" {
            await withKnownIssue("iOS does not trim a fromVariable timer token; Flutter does") { try await show() }
        } else {
            try await show()
        }
    }
}
