import Foundation
import Combine

/// Holds the in-progress state of one survey showing: the answers collected so
/// far, the position in the (possibly branching) node graph, and the back-stack
/// for the Back button.
@MainActor
final class SurveyViewModel: ObservableObject {
    let survey: SurveyConfigModel

    /// nodeId → answer.
    @Published private(set) var answers: [String: SurveyAnswer] = [:]
    @Published private(set) var currentNodeId: String
    @Published private(set) var isComplete: Bool
    @Published private(set) var redirectUrl: String?

    private var backStack: [String] = []
    private let canvasAnswerValidator = CanvasSurveyAnswerValidator()

    init(survey: SurveyConfigModel) {
        self.survey = survey
        let first = SurveyLogicHandler.firstNodeId(survey: survey, answers: [:])
        self.currentNodeId = first
        self.isComplete = (first == SURVEY_FINISHED)
    }

    var currentNode: SurveyNode? { survey.nodeById(currentNodeId) }
    var currentBlock: SurveyBlock? { currentNode.flatMap { survey.blockFor($0) } }

    /// 1-based position of the current node among the *question* (non-content)
    /// nodes on the path traversed so far. Used as `item_index` in survey events.
    var currentItemIndex: Int {
        (backStack + [currentNodeId]).reduce(0) { acc, nodeId in
            guard let node = survey.nodeById(nodeId),
                  let block = survey.blockFor(node),
                  !block.type.isContent
            else { return acc }
            return acc + 1
        }
    }

    var canGoBack: Bool { !backStack.isEmpty && survey.settings.pagination.backButton }

    /// Coarse progress estimate based on traversal depth, not graph topology.
    var progress: Double {
        guard !survey.nodes.isEmpty else { return 0 }
        return min(1.0, max(0.0, Double(backStack.count + 1) / Double(survey.nodes.count)))
    }

    func progressTotal(countQuestionsOnly: Bool = true) -> Int {
        max(1, progressNodeIds(countQuestionsOnly: countQuestionsOnly).count)
    }

    func progressCurrent(countQuestionsOnly: Bool = true) -> Int {
        let progressNodes = progressNodeIds(countQuestionsOnly: countQuestionsOnly)
        let total = max(1, progressNodes.count)
        let progressNodeIds = Set(progressNodes)
        let current = (backStack + [currentNodeId]).filter {
            progressNodeIds.contains($0)
        }.count
        return min(max(1, current), total)
    }

    func progressFraction(countQuestionsOnly: Bool = true) -> Double {
        let total = progressTotal(countQuestionsOnly: countQuestionsOnly)
        return min(1.0, max(0.0, Double(progressCurrent(countQuestionsOnly: countQuestionsOnly)) / Double(total)))
    }

    /// Whether the current node may be left — required questions must be answered.
    func canAdvance() -> Bool {
        guard let node = currentNode else { return false }
        if let scene = survey.canvasSurvey?.document(for: node) {
            if scene.kind != .question { return true }
            return canvasAnswerValidator.isComplete(input: scene.input, answer: answers[node.id])
        }
        guard let block = currentBlock else { return false }
        if block.type.isContent { return true }
        if !block.required { return true }
        return answers[node.id]?.isAnswered == true
    }

    func canvasValidationError() -> String? {
        guard let node = currentNode,
              let scene = survey.canvasSurvey?.document(for: node),
              scene.kind == .question
        else { return nil }
        return canvasAnswerValidator.validationError(input: scene.input, answer: answers[node.id])
    }

    func shouldAutoAdvance() -> Bool {
        guard survey.settings.autoAdvance else { return false }
        guard let node = currentNode, let answer = answers[node.id] else { return false }
        if let scene = survey.canvasSurvey?.document(for: node) {
            if scene.kind != .question { return false }
            return canvasAnswerValidator.autoAdvanceEligible(input: scene.input)
                && answer.isAnswered
                && canvasAnswerValidator.isComplete(input: scene.input, answer: answer)
        }
        guard let block = currentBlock else { return false }
        return block.type.isAutoAdvanceCandidate && answer.isAnswered
    }

    func setAnswer(_ nodeId: String, _ answer: SurveyAnswer) {
        answers[nodeId] = answer
    }

    func nextBlockIsResultPage() -> Bool {
        if isComplete || currentNodeId == SURVEY_FINISHED { return false }
        let navigation = SurveyLogicHandler.nextStep(survey: survey, currentNodeId: currentNodeId, answers: answers)
        guard let nextNode = survey.nodeById(navigation.nextNodeId) else { return false }
        return survey.blockFor(nextNode)?.type == .resultPage
    }

    /// Records the current answer and moves to the branching-decided next node.
    func advance() {
        if isComplete { return }
        let from = currentNodeId
        if from == SURVEY_FINISHED { return }
        let navigation = SurveyLogicHandler.nextStep(survey: survey, currentNodeId: from, answers: answers)
        backStack.append(from)
        redirectUrl = navigation.redirectUrl
        if navigation.nextNodeId == SURVEY_FINISHED {
            isComplete = true
        } else {
            currentNodeId = navigation.nextNodeId
        }
    }

    func back() {
        guard let prev = backStack.popLast() else { return }
        currentNodeId = prev
        isComplete = false
    }

    /// The collected answers as a serialisable map, for the `Completed` event.
    func responsePayload() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (nodeId, answer) in answers {
            out[nodeId] = .object(answer.toMap())
        }
        return out
    }

    private func progressNodeIds(countQuestionsOnly: Bool) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        var nodeId = survey.rootNode()?.id
        while let currentNodeId = nodeId, !seen.contains(currentNodeId) {
            seen.insert(currentNodeId)
            guard let node = survey.nodeById(currentNodeId) else { break }
            if node.isIncludedInProgress(in: survey, countQuestionsOnly: countQuestionsOnly) {
                ordered.append(node.id)
            }
            let navigation = SurveyLogicHandler.nextStep(
                survey: survey,
                currentNodeId: node.id,
                answers: answers
            )
            guard navigation.nextNodeId != SURVEY_FINISHED else { break }
            nodeId = navigation.nextNodeId
        }
        return ordered
    }
}

private extension SurveyNode {
    func isIncludedInProgress(in survey: SurveyConfigModel, countQuestionsOnly: Bool) -> Bool {
        if let canvasScene = survey.canvasSurvey?.document(for: self) {
            if canvasScene.kind == .result { return false }
            return !countQuestionsOnly || canvasScene.kind == .question
        }
        guard let block = survey.blockFor(self) else { return false }
        return !countQuestionsOnly || !block.type.isContent
    }
}
