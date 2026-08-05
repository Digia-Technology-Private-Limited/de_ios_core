import Combine
import UIKit

/// Binds one Semantic target to its matched live view. Layout reads are O(1) after
/// the initial tree match; a detached view gets one bounded same-page recovery.
@MainActor
final class SemanticTargetSession {
    private weak var root: UIView?
    private weak var matchedView: UIView?
    private let target: SemanticTarget
    private var recoveryUsed = false
    private var initialFailure: SemanticResolution?

    init(root: UIView, target: SemanticTarget) {
        self.root = root
        self.target = target
        initialFailure = bind(root)
    }

    func resolve(currentPageKey: String?) -> SemanticResolution {
        guard currentPageKey == target.pageKey else { return .pageMismatch }
        guard let root else { return .notVisible }
        if let rect = visibleRect(root) { return .resolved(rect) }
        if let initialFailure {
            self.initialFailure = nil
            return initialFailure
        }
        guard !recoveryUsed else { return .notVisible }
        recoveryUsed = true
        if let failure = bind(root) { return failure }
        return visibleRect(root).map(SemanticResolution.resolved) ?? .notVisible
    }

    private func bind(_ root: UIView) -> SemanticResolution? {
        let tree = SemanticViewTree.capture(root)
        let result = SemanticSelectorEvaluator.evaluate(nodes: tree.nodes, selector: target.selector)
        guard result.status == .matched, let node = result.node else {
            return result.status == .ambiguous ? .ambiguous(result.matchCount) : .notFound
        }
        matchedView = tree.viewsByNodeId[node.nodeId]
        return matchedView == nil ? .notFound : nil
    }

    private func visibleRect(_ root: UIView) -> CGRect? {
        guard let view = matchedView,
              view.window != nil,
              !view.isHidden,
              view.alpha > 0.01
        else { return nil }
        let rect = root.convert(view.bounds, from: view).intersection(root.bounds)
        return rect.isNull || rect.isEmpty ? nil : rect
    }
}

@MainActor
final class SemanticTargetSessionStore: ObservableObject {
    private var stepId: String?
    private var target: SemanticTarget?
    private weak var root: UIView?
    private var session: SemanticTargetSession?

    func resolve(
        stepId: String,
        root: UIView,
        currentPageKey: String?,
        target: SemanticTarget
    ) -> SemanticResolution {
        if self.stepId != stepId || self.target != target || self.root !== root {
            self.stepId = stepId
            self.target = target
            self.root = root
            session = SemanticTargetSession(root: root, target: target)
        }
        return session?.resolve(currentPageKey: currentPageKey) ?? .notFound
    }
}
