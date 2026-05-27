import Foundation

/// A single user answer. `values` holds the comparable tokens used by branching
/// (option ids, or `[score]`, or `[text]`); `comment` holds free-text such as
/// an "other" option's note.
struct SurveyAnswer: Equatable {
    let values: [String]
    let comment: String?

    init(values: [String] = [], comment: String? = nil) {
        self.values = values
        self.comment = comment
    }

    var isAnswered: Bool {
        values.contains { !$0.isEmpty } || !(comment ?? "").isEmpty
    }

    func toMap() -> [String: JSONValue] {
        [
            "values": .array(values.map { .string($0) }),
            "comment": comment.map { .string($0) } ?? .null,
        ]
    }

    /// Numeric view of a scalar answer (score / numeric input), or nil.
    func asNumber() -> Double? {
        guard let first = values.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Double(first)
    }
}

/// Sentinel id meaning "the survey is finished".
let SURVEY_FINISHED = "__digia_survey_finished__"

struct SurveyNavigation: Equatable {
    /// Target node id, or `SURVEY_FINISHED` when the survey should end.
    let nextNodeId: String
    let redirectUrl: String?

    init(nextNodeId: String, redirectUrl: String? = nil) {
        self.nextNodeId = nextNodeId
        self.redirectUrl = redirectUrl
    }
}

/// Pure branching runtime — operates on the node graph (no SwiftUI dependencies).
/// Resolves node-owned branching rules and conditional block visibility (`showWhen`).
enum SurveyLogicHandler {

    /// Id of the first node that should be shown, honouring `showWhen`.
    static func firstNodeId(survey: SurveyConfigModel, answers: [String: SurveyAnswer]) -> String {
        guard let root = survey.rootNode() else { return SURVEY_FINISHED }
        return scanForwardFrom(survey: survey, startNode: root, answers: answers, visited: [])
    }

    /// Decides the next node after `currentNodeId` has been answered. Always
    /// returns a valid node id or `SURVEY_FINISHED`.
    static func nextStep(
        survey: SurveyConfigModel,
        currentNodeId: String,
        answers: [String: SurveyAnswer]
    ) -> SurveyNavigation {
        guard let node = survey.nodeById(currentNodeId) else {
            return SurveyNavigation(nextNodeId: SURVEY_FINISHED)
        }
        let branching = node.branching

        if branching.type != .linear {
            for rule in branching.rules {
                if evaluateExpr(rule.whenExpr, ownerNode: node, branching: branching, answers: answers) {
                    return resolveTarget(survey: survey, currentNodeId: currentNodeId, target: rule.target, answers: answers)
                }
            }
        }
        return resolveTarget(survey: survey, currentNodeId: currentNodeId, target: branching.defaultTarget, answers: answers)
    }

    /// Whether `block` passes its `showWhen` given the answers so far.
    static func isVisible(block: SurveyBlock, ownerNodeId: String, answers: [String: SurveyAnswer]) -> Bool {
        guard let expr = block.showWhen else { return true }
        return evaluateExprForNode(expr: expr, defaultAnswerNodeId: ownerNodeId, answers: answers)
    }

    // MARK: - Internal helpers

    private static func scanForwardFrom(
        survey: SurveyConfigModel,
        startNode: SurveyNode,
        answers: [String: SurveyAnswer],
        visited: Set<String>
    ) -> String {
        var visited = visited
        var current: SurveyNode? = startNode
        while let node = current {
            if !visited.insert(node.id).inserted { return SURVEY_FINISHED }  // cycle guard
            let block = survey.blockFor(node)
            if block == nil || isVisible(block: block!, ownerNodeId: node.id, answers: answers) {
                return node.id
            }
            current = nextNodeAfter(survey: survey, node: node)
        }
        return SURVEY_FINISHED
    }

    private static func nextNodeAfter(survey: SurveyConfigModel, node: SurveyNode) -> SurveyNode? {
        let target = node.branching.defaultTarget
        switch target.kind {
        case .node:
            return survey.nodeById(target.nodeId)
        case .next:
            guard let idx = survey.nodes.firstIndex(where: { $0.id == node.id }), idx + 1 < survey.nodes.count else { return nil }
            return survey.nodes[idx + 1]
        case .url, .end:
            return nil
        }
    }

    private static func resolveTarget(
        survey: SurveyConfigModel,
        currentNodeId: String,
        target: BranchTarget,
        answers: [String: SurveyAnswer]
    ) -> SurveyNavigation {
        switch target.kind {
        case .end:
            return SurveyNavigation(nextNodeId: SURVEY_FINISHED)
        case .url:
            return SurveyNavigation(nextNodeId: SURVEY_FINISHED, redirectUrl: target.url.isEmpty ? nil : target.url)
        case .node:
            guard let next = survey.nodeById(target.nodeId) else {
                return SurveyNavigation(nextNodeId: SURVEY_FINISHED)
            }
            return SurveyNavigation(nextNodeId: scanForwardFrom(survey: survey, startNode: next, answers: answers, visited: []))
        case .next:
            guard let idx = survey.nodes.firstIndex(where: { $0.id == currentNodeId }), idx + 1 < survey.nodes.count else {
                return SurveyNavigation(nextNodeId: SURVEY_FINISHED)
            }
            let next = survey.nodes[idx + 1]
            return SurveyNavigation(nextNodeId: scanForwardFrom(survey: survey, startNode: next, answers: answers, visited: []))
        }
    }

    private static func evaluateExpr(
        _ expr: ConditionExpr,
        ownerNode: SurveyNode,
        branching: NodeBranching,
        answers: [String: SurveyAnswer]
    ) -> Bool {
        // by_parent rewrites a condition's nil nodeId to the configured parent;
        // by_condition (and linear fallback) treats nil nodeId as the owner.
        let defaultAnswerNodeId: String
        switch branching.type {
        case .byParent: defaultAnswerNodeId = branching.parentNodeId ?? ownerNode.id
        default: defaultAnswerNodeId = ownerNode.id
        }
        return evaluateExprForNode(expr: expr, defaultAnswerNodeId: defaultAnswerNodeId, answers: answers)
    }

    private static func evaluateExprForNode(
        expr: ConditionExpr,
        defaultAnswerNodeId: String,
        answers: [String: SurveyAnswer]
    ) -> Bool {
        let groupResults = expr.groups.map { group -> Bool in
            let conditionResults = group.conditions.map { condition -> Bool in
                let answerNodeId = condition.nodeId ?? defaultAnswerNodeId
                return evaluate(operator: condition.operator, targets: condition.values,
                                logicOp: group.operator, answer: answers[answerNodeId])
            }
            switch group.operator {
            case .and: return conditionResults.allSatisfy { $0 }
            case .or: return conditionResults.contains { $0 }
            }
        }
        switch expr.operator {
        case .and: return groupResults.allSatisfy { $0 }
        case .or: return groupResults.contains { $0 }
        }
    }

    private static func evaluate(
        operator op: ConditionOperator,
        targets: [String],
        logicOp: BoolOp,
        answer: SurveyAnswer?
    ) -> Bool {
        let answered = answer?.isAnswered == true
        switch op {
        case .isAnswered: return answered
        case .isNotAnswered: return !answered
        default: if !answered { return false }
        }

        guard let answer else { return false }
        let values = answer.values
        let parts = values + (answer.comment.map { [$0] } ?? [])
        let text = parts.joined(separator: " ").lowercased()

        switch op {
        case .equals, .isExactly:
            return Set(values) == Set(targets)
        case .notEquals:
            return Set(values) != Set(targets)
        case .includesAny:
            return targets.contains { values.contains($0) }
        case .includesAll:
            return targets.allSatisfy { values.contains($0) }
        case .contains:
            return combine(logicOp: logicOp, targets: targets) { text.contains($0.lowercased()) }
        case .notContains:
            return !combine(logicOp: logicOp, targets: targets) { text.contains($0.lowercased()) }
        case .greaterThan:
            guard let n = answer.asNumber(), let t = targets.first.flatMap(Double.init) else { return false }
            return n > t
        case .lessThan:
            guard let n = answer.asNumber(), let t = targets.first.flatMap(Double.init) else { return false }
            return n < t
        case .isBetween:
            guard let n = answer.asNumber(),
                  let low = targets.first.flatMap(Double.init),
                  targets.count > 1,
                  let high = Double(targets[1]) else { return false }
            return n >= min(low, high) && n <= max(low, high)
        case .isAnswered, .isNotAnswered:
            return true
        }
    }

    private static func combine(logicOp: BoolOp, targets: [String], predicate: (String) -> Bool) -> Bool {
        guard !targets.isEmpty else { return false }
        switch logicOp {
        case .and: return targets.allSatisfy(predicate)
        case .or: return targets.contains(where: predicate)
        }
    }
}
