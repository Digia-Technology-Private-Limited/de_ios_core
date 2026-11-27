import Foundation
import Testing
@testable import DigiaEngage

/// A PiP whose media URL is unusable is accepted and ends at once through the
/// normal dismissal path (dropped/cancelled), never invalid_config (#245).
@Suite("Media floater: sync media abandon", .tags(.unit, .floater))
@MainActor
struct PipSyncAbandonTests {

    private final class Recorded {
        var dismissed: (reason: FloaterDismissReason, wasVisible: Bool)?
        var completed = 0
    }

    @Test("an unusable media URL accepts and settles dropped/cancelled via onDismissed")
    func syncAbandonAccepts() throws {
        var json = try fixture("pip/pip_close_dismiss")
        var template = try #require(json["templateConfig"] as? [String: Any])
        var media = template["media"] as? [String: Any] ?? [:]
        // An unsupplied variable: parses (non-empty) but never resolves, so the
        // orchestrator abandons synchronously — the D07 degradation shape.
        media["url"] = "{{image}}"
        template["media"] = media
        json["templateConfig"] = template
        let campaign = try #require(try CampaignModel.fromJson(json, designTokens: fixtureTokens(json)))

        let recorded = Recorded()
        let orchestrator = FloaterOrchestrator(
            onDismissed: { _, reason, _, wasVisible in recorded.dismissed = (reason, wasVisible) },
            onCompleted: { _ in recorded.completed += 1 },
            onStepViewed: { _ in },
            onStepDismissed: { _ in },
            onVisible: { _ in }
        )
        defer { orchestrator.dispose() }
        let started = orchestrator.start(
            campaign,
            payload: CEPTriggerPayload(
                cepCampaignId: "sync-abandon", campaignKey: campaign.campaignKey, cepMetadata: [:]),
            screenName: nil
        )
        // Fails if: floater_orchestrator.swift `start` returns false for a sync
        // abandon, covering the dismissal callback's dropped/cancelled with
        // invalid_config (#245).
        #expect(started)
        #expect(recorded.dismissed?.reason == .mediaEnd)
        #expect(recorded.dismissed?.wasVisible == false)
        #expect(recorded.completed == 0)
        #expect(orchestrator.state == nil)
        #expect(orchestrator.lastStartFailedBusy == false)
    }
}
