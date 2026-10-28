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

    /// The survey is over: nothing of it on screen, completed once, and the CEP told it was
    /// dismissed.
    private func expectEnded(_ sdk: SdkHarness, _ presentation: CampaignPresentation) async throws {
        try await sdk.waitUntil("the survey ended") { SDKInstance.shared.surveyOrchestrator.state == nil }
        #expect(!sdk.isShowing(Self.role))
        #expect(!sdk.isShowing(Self.team))
        #expect(!sdk.isShowing(Self.trap))
        let names = try await sdk.eventNames(of: Self.key)
        #expect(names.filter { $0 == "Digia Experience Completed" }.count == 1, "sent: \(names)")
        try await sdk.waitUntil("the CEP is told") { presentation.dismissReason != nil }
    }

    // Fails if: canvas_survey_config_parser.swift `guard !conditions.isEmpty else { return nil }`
    // in `branchRule` is dropped: an empty `and` group is vacuously true in
    // `SurveyLogicHandler.evaluateExprForNode`, so every answer lands on the trap.
    @Test("a rule with no conditions never matches")
    func emptyRuleNeverMatches() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }

        try await pick(sdk, "Developer")

        try await reach(sdk, Self.team)
        #expect(!sdk.isShowing(Self.trap))
    }

    // Fails if: survey_logic_handler.swift `resolveTarget`'s `.node` case stops finishing when
    // `survey.nodeById(target.nodeId)` is nil.
    @Test("a fallback that points at a node that does not exist ends the survey instead of crashing")
    func ghostFallbackEnds() async throws {
        let (sdk, presentation) = try await open()
        defer { sdk.tearDown() }

        try await pick(sdk, "Something else")

        try await expectEnded(sdk, presentation)
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

    // Fails if: survey_logic_handler.swift `for rule in branching.rules` in `nextStep` stops
    // returning the first rule that matches (the Mobile+Web redirect rule then wins and the app
    // is sent to the browser, leaving the foreground).
    @Test("the first matching rule wins when several match")
    func firstMatchingRuleWins() async throws {
        let (sdk, presentation) = try await open()
        defer { sdk.tearDown() }
        try await pick(sdk, "Developer")
        try await reach(sdk, Self.team)

        try await sdk.tapExact("Mobile")
        try await sdk.tapExact("Web")
        try await sdk.tapExact("Data")
        try await sdk.surveyNext()

        try await expectEnded(sdk, presentation)
        // iOS opens a redirect with `UIApplication.shared.open`, nothing the SDK lets a test
        // observe; a redirect would leave the app for the browser.
        #expect(UIApplication.shared.applicationState == .active)
    }

    /// The redirect route. iOS opens a redirect target with `UIApplication.shared.open`
    /// (survey_renderer.swift, `.onChange(of: vm.redirectUrl)`), not through the host app's
    /// deep-link handler as Flutter does, so there is nothing to assert on and running the route
    /// would send the simulator to Safari, taking the test app out of the foreground for every
    /// suite after it.
    @Test("a redirect target ends the survey and opens its link once, reading an earlier question for its second condition",
          .disabled("iOS opens a survey redirect with UIApplication.shared.open, bypassing the deep-link handler; running it backgrounds the test app"))
    func redirectOpensLinkOnce() async throws {
        let (sdk, presentation) = try await open()
        defer { sdk.tearDown() }
        let links = Received<String>()
        sdk.setDeepLinkHandler { links.append($0) }
        try await pick(sdk, "Developer")
        try await reach(sdk, Self.team)

        try await sdk.tapExact("Mobile")
        try await sdk.tapExact("Web")
        try await sdk.surveyNext()

        try await expectEnded(sdk, presentation)
        #expect(links.values == ["https://example.com/engage-survey-redirect"])
    }

    // Fails if: survey_logic_handler.swift `resolveTarget`'s `.next` case stops taking
    // `survey.nodes[idx + 1]`.
    @Test("a rule that does not match falls back to the next node")
    func unmatchedFallsBackToNext() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }
        try await pick(sdk, "Developer")
        try await reach(sdk, Self.team)

        try await pick(sdk, "Mobile")

        try await reach(sdk, Self.age)
        #expect(UIApplication.shared.applicationState == .active)
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

    // Fails if: survey_logic_handler.swift `default: if !answered { return false }` in `evaluate`
    // is dropped for an unanswered source.
    @Test("a condition on a question that was skipped fails, so the rule does not match")
    func skippedSourceFailsCondition() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }
        try await reachAge(sdk)

        try await sdk.surveyNext()
        try await reach(sdk, Self.feedback)
        try await sdk.surveyNext()

        try await reach(sdk, Self.result)
        #expect(!sdk.isShowing(Self.guardian))
    }
}
}
