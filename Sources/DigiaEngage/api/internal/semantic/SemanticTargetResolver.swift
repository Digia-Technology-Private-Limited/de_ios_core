import UIKit

enum SemanticResolution {
    case resolved(CGRect)
    case pageMismatch
    case notFound
    case ambiguous(Int)
    case notVisible
}

@MainActor
enum SemanticTargetResolver {
    static func resolve(
        root: UIView,
        currentPageKey: String?,
        target: SemanticTarget
    ) -> SemanticResolution {
        guard currentPageKey == target.pageKey else { return .pageMismatch }
        let tree = SemanticViewTree.capture(root)
        let result = SemanticSelectorEvaluator.evaluate(nodes: tree.nodes, selector: target.selector)
        guard result.status == .matched, let node = result.node else {
            return result.status == .ambiguous ? .ambiguous(result.matchCount) : .notFound
        }
        guard let view = tree.viewsByNodeId[node.nodeId],
              view.window != nil,
              !view.isHidden,
              view.alpha > 0.01
        else { return .notVisible }
        let rect = root.convert(view.bounds, from: view).intersection(root.bounds)
        return rect.isNull || rect.isEmpty ? .notVisible : .resolved(rect)
    }
}
