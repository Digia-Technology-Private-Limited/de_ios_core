import Foundation
import Testing
@testable import DigiaEngage

/// A story floater authored with `behavior.initialState: "expanded"` opens straight into its
/// story. The user never tapped, so it reports no expands — but they saw the story, so the showing
/// still completes and its engaged time runs from the first painted frame.
///
/// Fixture: `floater/floater_story_video`, with `initialState` set on the loaded copy. Driven
/// through `FloaterStoryOrchestrator` directly with a scripted clock, as Flutter drives its own.
/// Port of `flutter/core/test/floater_story_start_expanded_test.dart`.
@Suite("Media floater: start-expanded story floater", .tags(.unit, .floater))
@MainActor
struct MediaFloaterStoryStartExpandedTests {

    private final class Recorded {
        var completed = 0
        var visible = 0
        var dismissed: (reason: FloaterDismissReason, metrics: FloaterMetrics, wasVisible: Bool)?
    }

    private func startExpanded() throws -> (FloaterStoryOrchestrator, Recorded, clock: () -> Void) {
        var json = try fixture("floater/floater_story_video")
        var template = try #require(json["templateConfig"] as? [String: Any])
        var behavior = template["behavior"] as? [String: Any] ?? [:]
        behavior["initialState"] = "expanded"
        template["behavior"] = behavior
        json["templateConfig"] = template
        let campaign = try #require(try CampaignModel.fromJson(json, designTokens: fixtureTokens(json)))

        let recorded = Recorded()
        let orchestrator = FloaterStoryOrchestrator(
            onDismissed: { _, reason, metrics, wasVisible in
                recorded.dismissed = (reason, metrics, wasVisible)
            },
            onCompleted: { _ in recorded.completed += 1 },
            onStepViewed: { _ in },
            onStepDismissed: { _ in },
            onVisible: { _ in recorded.visible += 1 }
        )
        var nowMs: Int64 = 1_000
        orchestrator.now = { nowMs }
        let started = orchestrator.start(
            campaign,
            payload: CEPTriggerPayload(
                cepCampaignId: "start-expanded", campaignKey: campaign.campaignKey, cepMetadata: [:]),
            screenName: nil
        )
        try #require(started, "\(orchestrator.lastStartFailureReason ?? "")")
        return (orchestrator, recorded, { nowMs += 4_000 })
    }

    // Fails if: floater_story_orchestrator.swift `markVisible` `everOpened = true` is deleted.
    // Fails if: floater_story_orchestrator.swift `markVisible` `storyStartedAtMs = now()` is deleted.
    @Test("a start-expanded story floater opens, completes, and counts no expands")
    func opensCompletesAndCountsNoExpands() throws {
        let (orchestrator, recorded, fourSecondsPass) = try startExpanded()
        defer { orchestrator.dispose() }
        #expect(orchestrator.storyOpen)

        orchestrator.markVisible(token: try #require(orchestrator.state).token)
        fourSecondsPass()
        orchestrator.dismiss(.userClose)

        #expect(recorded.completed == 1)
        let dismissed = try #require(recorded.dismissed)
        #expect(dismissed.metrics.expands == 0, "the user never tapped")
        #expect(dismissed.metrics.engagedMs == 4_000)
        #expect(dismissed.wasVisible)
    }

    // Not in Flutter's test: the other half of "the impression is the first painted frame".
    // Fails if: floater_story_orchestrator.swift `dismiss` `if everOpened { complete() }` ->
    // `complete()` (a story nobody saw retires the campaign).
    @Test("a start-expanded showing that is never painted completes nothing and reports no engaged time")
    func unpaintedShowingDoesNotComplete() throws {
        let (orchestrator, recorded, fourSecondsPass) = try startExpanded()
        defer { orchestrator.dispose() }

        fourSecondsPass()
        orchestrator.dismiss(.screenExit)

        #expect(recorded.completed == 0)
        #expect(recorded.visible == 0)
        let dismissed = try #require(recorded.dismissed)
        #expect(!dismissed.wasVisible)
        #expect(dismissed.metrics.engagedMs == 0)
    }
}
