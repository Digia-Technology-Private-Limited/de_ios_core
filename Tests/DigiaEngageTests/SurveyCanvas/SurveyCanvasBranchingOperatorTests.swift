import Foundation
import Testing
@testable import DigiaEngage

/// The canvas survey's branching operators that `survey_branching_rules` does not author: each
/// case parses a three-scene canvas survey whose first node has one rule (one condition) leading to
/// `node_yes`, falling back to `node_no`, and asks `SurveyLogicHandler.nextStep` where an answer
/// goes. The fixture suite (`FixtureBehaviour/SurveyGuide/SurveyBranchingRulesTests`) covers
/// equals, greater/less than, an in-range between, `or`, first match, redirects and skipped
/// sources; these are the remaining operator decisions.
///
/// Flutter covers branching only through `flutter/core/test/fixture_behaviour/survey_branching_rules_test.dart`;
/// these are iOS additions for the operators that fixture leaves out.
@Suite("Canvas survey: branching operators", .tags(.unit, .survey))
@MainActor
struct SurveyCanvasBranchingOperatorTests {

    private func survey(operator op: String, value: String) throws -> SurveyConfigModel {
        let json = """
        { "templateType": "survey", "layoutMode": "canvas", "schemaVersion": 1,
          "scenes": [
            { "id": "scene_q", "kind": "question",
              "input": { "type": "multi_select", "required": false,
                         "options": [ { "id": "a", "label": "A" }, { "id": "b", "label": "B" }, { "id": "c", "label": "C" } ] } },
            { "id": "scene_yes", "kind": "result" },
            { "id": "scene_no", "kind": "result" }
          ],
          "flow": { "rootNodeId": "node_q", "nodes": [
            { "id": "node_q", "sceneId": "scene_q",
              "rules": [ { "id": "rule", "conditions": [ { "operator": "\(op)", "value": \(value) } ],
                           "target": { "kind": "node", "nodeId": "node_yes" } } ],
              "fallback": { "kind": "node", "nodeId": "node_no" } },
            { "id": "node_yes", "sceneId": "scene_yes", "rules": [], "fallback": { "kind": "end" } },
            { "id": "node_no", "sceneId": "scene_no", "rules": [], "fallback": { "kind": "end" } }
          ] } }
        """
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
            throw CancellationError()
        }
        return try #require(try CanvasSurveyConfigParser.from(object, fallbackId: "operators"))
    }

    /// Where [answer] on the first question leads: true for the rule's target, false for the fallback.
    private func matches(_ op: String, _ value: String, answer: SurveyAnswer?) throws -> Bool {
        let survey = try survey(operator: op, value: value)
        let answers = answer.map { ["node_q": $0] } ?? [:]
        let next = SurveyLogicHandler.nextStep(survey: survey, currentNodeId: "node_q", answers: answers).nextNodeId
        #expect(next == "node_yes" || next == "node_no", "unexpected \(next)")
        return next == "node_yes"
    }

    private func values(_ values: String...) -> SurveyAnswer { SurveyAnswer(values: values) }

    // Fails if: survey_logic_handler.swift `.notEquals` stops comparing the whole selection
    // (`Set(values) != Set(targets)`), or the operator's spellings stop mapping to it.
    @Test("not equals: any selection other than the value", arguments: ["not_equals", "is_not", "not-equal"])
    func notEquals(_ op: String) throws {
        #expect(try matches(op, #""a""#, answer: values("b")))
        #expect(try !matches(op, #""a""#, answer: values("a")))
    }

    // Fails if: survey_logic_handler.swift `.includesAny` stops matching on one shared option, or
    // `.includesAll` stops requiring every target.
    @Test("includes any needs one target chosen; includes all needs every target")
    func includesAnyAndAll() throws {
        #expect(try matches("includes_any", #"["a", "c"]"#, answer: values("c")))
        #expect(try !matches("includes_any", #"["a", "c"]"#, answer: values("b")))
        #expect(try matches("includes_all", #"["a", "b"]"#, answer: values("b", "c", "a")))
        #expect(try !matches("includes_all", #"["a", "b"]"#, answer: values("a", "c")))
    }

    // Fails if: survey_logic_handler.swift `.isExactly` starts depending on the order the options
    // were tapped in, or lets a selection with an extra option through.
    @Test("is exactly: the same options in any order, and no others")
    func isExactly() throws {
        #expect(try matches("is_exactly", #"["a", "b"]"#, answer: values("b", "a")))
        #expect(try !matches("is_exactly", #"["a", "b"]"#, answer: values("a", "b", "c")))
    }

    // Fails if: survey_logic_handler.swift `.contains` / `.notContains` stop lower-casing both
    // sides, or stop reading the answer's comment along with its values.
    @Test("contains and does-not-contain ignore case and read the comment too")
    func containsIgnoresCase() throws {
        #expect(try matches("contains", #""DELIVERY""#, answer: values("Fast delivery")))
        #expect(try matches("answer_contains", #""late""#, answer: SurveyAnswer(values: ["other"], comment: "Came LATE")))
        #expect(try !matches("contains", #""refund""#, answer: values("Fast delivery")))
        #expect(try matches("not_contains", #""slow""#, answer: values("Fast delivery")))
        #expect(try !matches("answer_does_not_contain", #""fast""#, answer: values("Fast delivery")))
    }

    // Fails if: survey_logic_handler.swift `.isBetween` stops ordering its bounds
    // (`min(low, high)` / `max(low, high)`), or matches with only one bound.
    @Test("between accepts its bounds in either order, ends included, and needs both")
    func betweenEitherOrder() throws {
        #expect(try matches("is_between", #"["10", "5"]"#, answer: values("5")))
        #expect(try matches("between", #"["10", "5"]"#, answer: values("10")))
        #expect(try !matches("is_between", #"["10", "5"]"#, answer: values("11")))
        #expect(try !matches("is_between", #"["5"]"#, answer: values("7")))
    }

    // Fails if: survey_logic_handler.swift `case .isNotAnswered: return !answered` changes, or a
    // numeric operator starts matching an answer that is not a number.
    @Test("is not answered matches only a skipped question; a number rule never matches text")
    func notAnsweredAndNonNumeric() throws {
        #expect(try matches("is_not_answered", #""""#, answer: nil))
        #expect(try matches("not_known", #""""#, answer: values("")))
        #expect(try !matches("is_not_answered", #""""#, answer: values("a")))
        #expect(try !matches("greater_than", #""3""#, answer: values("lots")))
    }

    // Fails if: survey_logic_handler.swift `nextStep` stops finishing for a node id it does not
    // know (`guard let node = survey.nodeById(currentNodeId)`).
    @Test("an unknown current node finishes the survey")
    func unknownNodeFinishes() throws {
        let survey = try survey(operator: "equals", value: #""a""#)
        #expect(SurveyLogicHandler.nextStep(survey: survey, currentNodeId: "nowhere", answers: [:]).nextNodeId
            == SURVEY_FINISHED)
    }
}
