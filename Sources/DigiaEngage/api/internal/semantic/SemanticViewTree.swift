import UIKit

struct CapturedSemanticTree {
    let nodes: [SemanticNodeSnapshot]
    let viewsByNodeId: [String: UIView]
}

@MainActor
enum SemanticViewTree {
    static func capture(_ root: UIView) -> CapturedSemanticTree {
        var nodes: [SemanticNodeSnapshot] = []
        var viewsByNodeId: [String: UIView] = [:]

        func descendantText(_ view: UIView) -> [String] {
            var values: [String] = []
            if let text = ownText(view) { values.append(text) }
            for child in view.subviews {
                values.append(contentsOf: descendantText(child))
            }
            return Array(Set(values.map(SemanticSelectorEvaluator.normalize).filter { !$0.isEmpty }))
        }

        func visit(_ view: UIView, id: String, parentId: String?, index: Int) {
            let rect = root.convert(view.bounds, from: view).intersection(root.bounds)
            let actionable = view is UIControl
                || view.accessibilityTraits.contains(.button)
                || view.accessibilityTraits.contains(.link)
                || view.gestureRecognizers?.contains(where: { $0.isEnabled }) == true
            let identifier = view.accessibilityIdentifier?.nilIfBlank
            let node = SemanticNodeSnapshot(
                nodeId: id,
                parentId: parentId,
                className: String(describing: type(of: view)),
                role: role(view, actionable: actionable),
                resourceId: identifier,
                testId: identifier,
                text: ownText(view),
                contentDescription: view.accessibilityLabel?.nilIfBlank,
                descendantText: descendantText(view),
                indexInParent: index,
                actionable: actionable,
                enabled: (view as? UIControl)?.isEnabled ?? view.isUserInteractionEnabled,
                visible: view.window != nil && !view.isHidden && view.alpha > 0.01 && !rect.isNull && !rect.isEmpty,
                bounds: rect.isNull || rect.isEmpty ? nil : rect
            )
            nodes.append(node)
            viewsByNodeId[id] = view
            for (childIndex, child) in view.subviews.enumerated() {
                visit(child, id: "\(id).\(childIndex)", parentId: id, index: childIndex)
            }
        }

        visit(root, id: "0", parentId: nil, index: 0)
        return CapturedSemanticTree(nodes: nodes, viewsByNodeId: viewsByNodeId)
    }

    private static func ownText(_ view: UIView) -> String? {
        if let label = view as? UILabel { return label.text?.nilIfBlank }
        if let button = view as? UIButton { return button.title(for: .normal)?.nilIfBlank }
        if let field = view as? UITextField { return field.text?.nilIfBlank }
        if let textView = view as? UITextView { return textView.text?.nilIfBlank }
        return nil
    }

    private static func role(_ view: UIView, actionable: Bool) -> String? {
        if view is UISwitch { return "switch" }
        if view is UITextField || view is UITextView { return "textbox" }
        if view.accessibilityTraits.contains(.link) { return "link" }
        if view is UIButton || view.accessibilityTraits.contains(.button) || actionable { return "button" }
        if view is UILabel { return "text" }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
