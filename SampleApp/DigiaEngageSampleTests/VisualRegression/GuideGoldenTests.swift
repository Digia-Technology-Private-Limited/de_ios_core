// tags: golden guide
import Testing

/// Every guide fixture (`sdk_testing_fixtures/campaigns/<guide_tooltip|guide_spotlight|anchorless>`) is
/// delivered through the real SDK over a host screen inside `DigiaHost`. Anchored steps attach to the
/// `DigiaAnchor`s the host places at fixed positions; anchorless steps resolve their captured geometry on the
/// host's reported screen. Each golden is the guide's first step: the bubble, its arrow and, for spotlights,
/// the dimmed scrim and cutout.
///
/// Anchorless crops are CDN images; the stub backend draws the Test Kit's `strawberry.jpg` inside each cutout.
///
/// Regenerate baselines after an intentional visual change:
///   RECORD_SNAPSHOTS=true ./run-tests.sh guide
@MainActor
@Suite("guide goldens", .serialized, .enabled(if: WorkspaceFixtures.skipReason == nil, "Test Kit missing"))
struct GuideGoldenTests {
    /// Fixtures with no step the SDK can draw, so there is nothing to render; each is asserted to be turned
    /// away, and fails once it gains a step so it can get a golden. A classic (non-canvas) tooltip step: guides
    /// render canvas steps only.
    private static let dropped: Set<String> = ["guide_tooltip_classic_stack_push"]

    /// Fixtures the SDK starts but never shows. Each is asserted to stay hidden, and fails once it shows.
    ///   - an anchor that is not on screen;
    ///   - anchorless targets for another page, or placed off screen (the page-key and bounds guards).
    private static let notShown: Set<String> = ["guide_spotlight_missing", "anchorless_mismatch", "anchorless_out_of_bounds"]

    @Test("guide_tooltip", arguments: WorkspaceFixtures.campaigns(in: "guide_tooltip"))
    func tooltip(_ fixture: WorkspaceFixtures.Campaign) async throws { try await run(fixture, surface: "guide_tooltip") }

    @Test("guide_spotlight", arguments: WorkspaceFixtures.campaigns(in: "guide_spotlight"))
    func spotlight(_ fixture: WorkspaceFixtures.Campaign) async throws { try await run(fixture, surface: "guide_spotlight") }

    @Test("anchorless", arguments: WorkspaceFixtures.campaigns(in: "anchorless"))
    func anchorless(_ fixture: WorkspaceFixtures.Campaign) async throws { try await run(fixture, surface: "anchorless") }

    private func run(_ fixture: WorkspaceFixtures.Campaign, surface: String) async throws {
        if Self.dropped.contains(fixture.name) {
            try await GoldenHarness.expectGuideDropped(fixture)
        } else if Self.notShown.contains(fixture.name) {
            try await GoldenHarness.expectGuideNotShown(fixture)
        } else {
            try await GoldenHarness.expectFixtureGolden(fixture, surface: surface, host: .guide, settle: 2)
        }
    }
}
