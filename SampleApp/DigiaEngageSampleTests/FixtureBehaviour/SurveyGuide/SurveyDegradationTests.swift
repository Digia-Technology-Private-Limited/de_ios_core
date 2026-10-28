import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// The `degrade_survey_*` fixtures are surveys this build must not show, or must show only in
/// part. They arrive in one campaign bundle with a good survey
/// (`survey_welcome_backdrop_stepback`) in the middle, are parsed by the real fetcher, and are
/// triggered by a CEP the way a customer's app would. A bad campaign has to be dropped alone:
/// nothing shows for it, the survey beside it still does, and the fleet-health report says why.
///
/// Port of `flutter/core/test/fixture_behaviour/survey_degradation_test.dart`.
@Suite("Survey: degradation", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyDegradationTests {

    private static let goodKey = "test_survey_welcome_backdrop_stepback"
    /// Dropped by the parser as unreadable, by the key each reports under.
    private static let unreadable = [
        "test_degrade_survey_flow_root_missing",
        "test_degrade_survey_no_design_width",
        "test_degrade_survey_no_scenes",
        "test_degrade_survey_not_a_survey_template",
        "test_degrade_survey_schema_older",
    ]
    /// Known gap: three of the surveys Flutter drops as unreadable are parsed and shown by iOS,
    /// which repairs them in canvas_survey_config_parser.swift instead of rejecting them:
    ///   flow_root_missing  `rootNodeId` names no node; iOS falls back to `nodes.first?.id`
    ///   no_design_width    `designWidth: 0`; `designWidth(_:)` falls back to 360
    ///   schema_older       `schemaVersion: 0`; `schemaVersion(_:)` reads it as the supported 1
    ///                      (`SurveyParse.int(raw) ?? 1`), so `acceptsVersion` never sees 0
    /// Each is checked under `withKnownIssue`, which fails the day iOS drops it, the cue to move
    /// it out of this set.
    private static let iosKeeps: Set<String> = [
        "test_degrade_survey_flow_root_missing",
        "test_degrade_survey_no_design_width",
        "test_degrade_survey_schema_older",
    ]
    private static let newerKey = "test_degrade_survey_schema_newer"
    private static let partialKey = "test_degrade_survey_partial_scenes"

    private func boot() async throws -> SdkHarness {
        // Dedup is per app session and the sink is a singleton, so a reason reported by an
        // earlier test would hide the same reason in this one.
        HealthSink.shared.resetForTest()
        let degrade = { (name: String) in "campaigns/degradation/degrade_survey_\(name).json" }
        return try await SdkHarness.surveyGuideStart([
            degrade("flow_root_missing"),
            degrade("no_design_width"),
            degrade("no_scenes"),
            // A readable survey among the unreadable ones.
            "campaigns/survey/survey_welcome_backdrop_stepback.json",
            degrade("not_a_survey_template"),
            degrade("schema_older"),
            degrade("schema_newer"),
            degrade("partial_scenes"),
        ])
    }

    // Fails if: CampaignBundle.swift stops skipping a campaign `CampaignModel.fromJson` returns
    // nil for (the bad survey then reaches the store and is routed).
    @Test("an unreadable survey is dropped alone: nothing shows for it, and the survey beside it still does")
    func unreadableDroppedAlone() async throws {
        let sdk = try await boot()
        defer { sdk.tearDown(); HealthSink.shared.resetForTest() }

        for key in Self.unreadable + [Self.newerKey] {
            let presentation = try sdk.deliver(key)
            try await sdk.settle()
            let shown = SDKInstance.shared.surveyOrchestrator.state != nil
            let dropReason = presentation.dropReason
            // One shown by mistake would hold the survey surface for the next delivery.
            if shown {
                SDKInstance.shared.markSurveyDismissed()
                try await sdk.settle()
            }
            let expectDropped = {
                #expect(!shown, "\(key) must not put a survey on screen")
                #expect(dropReason == .unknownCampaignKey,
                        "\(key) is not in the store, so the CEP is told no such campaign")
            }
            if Self.iosKeeps.contains(key) {
                withKnownIssue("iOS repairs and shows \(key) instead of dropping it", expectDropped)
            } else {
                expectDropped()
            }
        }

        let good = try await sdk.openSurvey(Self.goodKey, firstText: "Help Us Improve Digia")
        #expect(good.outcome.settledValue == nil, "still showing")
    }

    // Fails if: CampaignBundle.swift `catch is ReportedParseFailure { return nil }` falls through
    // to the `malformed_campaign_skipped` report (the newer schema then counts twice), or
    // `CampaignParseScope.acceptsVersion` stops reporting `schema_version_too_new`.
    @Test("each unreadable survey is reported once under its own reason, and the newer schema is reported as such and not as malformed")
    func reportedOnceEach() async throws {
        let sdk = try await boot()
        defer { sdk.tearDown(); HealthSink.shared.resetForTest() }

        // The reports are sent while `initialize` runs (the bundle is parsed then), so they are
        // read from every `/track` request of this run, not from `events()`, which counts only
        // what was sent after start.
        var health: [[String: Any]] = []
        for _ in 0..<10 {
            health = try await sdk.trackedSinceStart().filter { $0["event_name"] as? String == "sdk_health" }
            if health.contains(where: { SdkHarness.props($0)["reason"] as? String == "schema_version_too_new" }) { break }
            try await sdk.settle(0.3)
        }
        let malformedKeys = health
            .filter { SdkHarness.props($0)["reason"] as? String == "malformed_campaign_skipped" }
            .compactMap { $0["campaign_key"] as? String }
        let newer = health.filter { SdkHarness.props($0)["reason"] as? String == "schema_version_too_new" }

        // Every campaign the parser returned nil for, once each.
        let sent = health.map { "\($0["campaign_key"] ?? "-"): \(SdkHarness.props($0)["reason"] ?? "-")" }
        #expect(malformedKeys.sorted() == Self.unreadable.filter { !Self.iosKeeps.contains($0) }.sorted(),
                "sdk_health sent: \(sent)")
        withKnownIssue("iOS repairs three of the unreadable surveys, so they are never reported") {
            #expect(malformedKeys.sorted() == Self.unreadable.sorted())
        }
        #expect(newer.count == 1)
        #expect(newer.first?["campaign_key"] as? String == Self.newerKey)
        let detail = newer.first.map(SdkHarness.props)?["detail"] as? [String: Any]
        #expect(detail?["required"] as? String == "2")
        #expect(detail?["supported"] as? String == "1")
    }

    // Fails if: canvas_survey_config_parser.swift stops skipping a scene or node that is not an
    // object (`compactMap { SurveyParse.object($0) }`), dropping the whole survey instead.
    @Test("a survey with junk among its scenes and flow nodes is kept and runs on the entries that are readable")
    func partialScenesRun() async throws {
        let sdk = try await boot()
        defer { sdk.tearDown(); HealthSink.shared.resetForTest() }

        try await sdk.openSurvey(Self.partialKey, firstText: "A question")
        try await sdk.tapExact("A")
        try await sdk.surveyNext()
        try await sdk.waitUntil("the survey completes") { SDKInstance.shared.surveyOrchestrator.state == nil
            || !sdk.isShowing("A question") }

        #expect(try await sdk.questionsViewed(Self.partialKey) == ["node_q"])
        let completed = try await sdk.only("Digia Experience Completed", of: Self.partialKey)
        #expect(completed["answered_count"] as? Int == 1)
        let response = try #require(completed["response"] as? [String: Any])
        #expect(Array(response.keys) == ["node_q"])
        let answer = try #require(surveyAnswer(response, "node_q"))
        #expect(answer.values == ["o_a"])
        #expect(answer.noComment)
    }
}
}
