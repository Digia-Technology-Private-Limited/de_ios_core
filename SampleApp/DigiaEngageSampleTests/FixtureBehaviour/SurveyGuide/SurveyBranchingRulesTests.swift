import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// `survey_branching_rules`: where a respondent lands depends on the rules on the question they
/// just answered. Each test takes one route through the real survey and reads which screen comes
/// next, or that the survey ended.
///
/// Routes in the fixture:
///   role      first rule has NO conditions and leads to a trap scene; then Developer -> team,
///             Designer-or-Product-manager -> age, and anything else falls back to a node that
///             does not exist
///   team      Data ends the survey; Mobile+Web (as a Developer) redirects; anything else goes to
///             the next node, age
///   age       18..40 goes to the result; anything else goes to feedback, whose rule reads the
///             age: under 18 -> a guardian note
///
/// Port of `flutter/core/test/fixture_behaviour/survey_branching_rules_test.dart`.
@Suite("Survey: branching rules", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyBranchingRulesTests {

    private static let key = "test_survey_branching_rules"
    private static let role = "What is your role?"
    private static let team = "Which teams do you work with?"
    private static let age = "How old are you? (optional)"
    private static let feedback = "Any feedback? (optional)"
    private static let guardian = "Ask a guardian first"
    private static let result = "All done"
    private static let trap = "TRAP: a rule with no conditions matched"

    private func open() async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.surveyGuideStart(["campaigns/survey/survey_branching_rules.json"])
        let presentation = try await sdk.openSurvey(Self.key, firstText: Self.role)
        return (sdk, presentation)
    }

    private func pick(_ sdk: SdkHarness, _ option: String) async throws {
        try await sdk.tapExact(option)
        try await sdk.surveyNext()
    }

    /// Reaches the age question the one way iOS can: Developer, then Mobile alone, whose rules do
    /// not match and fall back to the next node. (Flutter goes through Designer; on iOS the
    /// Designer-or-Product-manager `or` rule never matches, see ``orNeedsOneCondition()``.)
    private func reachAge(_ sdk: SdkHarness) async throws {
        try await pick(sdk, "Developer")
        try await reach(sdk, Self.team)
        try await pick(sdk, "Mobile")
        try await reach(sdk, Self.age)
    }

    private func reach(_ sdk: SdkHarness, _ text: String) async throws {
        try await sdk.waitUntil("\"\(text)\" on screen") { sdk.isShowing(text) }
    }

    /// Known gap: canvas_survey_config_parser.swift `branchRule` puts the rule's
    /// `conditionOperator` on the outer `ConditionExpr` but every condition in one
    /// `ConditionGroup(operator: .and, ...)`, so an `or` rule needs all of its conditions, like an
    /// `and`. Flutter's `CanvasSurveyConditionOperator.or => matches.any`. "Product manager"
    /// matches only the second condition, so iOS falls back to the missing node and ends the
    /// survey instead of asking the age.
    // Fails if: the group operator is fixed (the known issue then passes and `withKnownIssue`
    // fails, the cue to drop it).
    @Test("or: either condition is enough")
    func orNeedsOneCondition() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }

        try await pick(sdk, "Product manager")

        try await withKnownIssue("iOS evaluates a canvas survey rule's `or` conditions as `and`") {
            try await reach(sdk, Self.age)
        }
        #expect(!sdk.isShowing(Self.trap))
    }

    // Fails if: survey_logic_handler.swift `isBetween` stops including its range
    // (`n >= min(low, high) && n <= max(low, high)` becomes always false).
    @Test("an answer inside the range jumps past the feedback question")
    func inRangeSkipsFeedback() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }
        try await reachAge(sdk)

        try await sdk.type("25")
        try await sdk.surveyNext()

        try await reach(sdk, Self.result)
        #expect(!sdk.isShowing(Self.feedback))
    }

    // Fails if: survey_logic_handler.swift `case .lessThan: ... return n < t` stops reading the
    // earlier question (`condition.nodeId ?? defaultAnswerNodeId` in `evaluateExprForNode`).
    @Test("a rule on a later question reads the age answered before it")
    func laterRuleReadsEarlierAnswer() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }
        try await reachAge(sdk)

        try await sdk.type("17")
        try await sdk.surveyNext()
        try await reach(sdk, Self.feedback)
        try await sdk.surveyNext()

        try await reach(sdk, Self.guardian)
    }
}
}
