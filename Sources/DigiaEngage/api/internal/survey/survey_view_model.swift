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

    /// Whether the current node may be left — required questions must be answered.
    func canAdvance() -> Bool {
        guard let block = currentBlock else { return false }
        if block.type.isContent { return true }
        if !block.required { return true }
        return answers[currentNodeId]?.isAnswered == true
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
}
