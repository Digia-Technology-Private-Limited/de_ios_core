import CoreGraphics
import Foundation
import UIKit

struct SemanticPredicate: Equatable {
    let className: String?
    let role: String?
    let resourceId: String?
    let testId: String?
    let text: String?
    let contentDescription: String?
    let descendantText: String?

    init(
        className: String? = nil,
        role: String? = nil,
        resourceId: String? = nil,
        testId: String? = nil,
        text: String? = nil,
        contentDescription: String? = nil,
        descendantText: String? = nil
    ) {
        self.className = className
        self.role = role
        self.resourceId = resourceId
        self.testId = testId
        self.text = text
        self.contentDescription = contentDescription
        self.descendantText = descendantText
    }

    var isEmpty: Bool {
        [className, role, resourceId, testId, text, contentDescription, descendantText]
            .allSatisfy { $0 == nil }
    }
}

struct SemanticSelectorV1: Equatable {
    let node: SemanticPredicate
    let ancestors: [SemanticPredicate]
    let indexAmongMatches: Int?
}

struct SemanticTarget: Equatable {
    let pageKey: String
    let selector: SemanticSelectorV1

    static func fromJson(_ json: [String: Any]?) -> SemanticTarget? {
        guard let json,
              json.string("type") == "semantic",
              !["x", "y", "width", "height", "region"].contains(where: { json[$0] != nil }),
              let pageKey = json.nonBlankString("pageKey"),
              let rawSelector = json.object("selector"),
              rawSelector.int("version", default: -1) == 1,
              let rawNode = rawSelector.object("node")
        else { return nil }

        let node = predicate(rawNode)
        guard !node.isEmpty else { return nil }
        let ancestors = (rawSelector["ancestors"] as? [[String: Any]] ?? [])
            .map(predicate)
            .filter { !$0.isEmpty }
        let index = rawSelector["indexAmongMatches"] as? Int
        return SemanticTarget(
            pageKey: pageKey,
            selector: SemanticSelectorV1(
                node: node,
                ancestors: ancestors,
                indexAmongMatches: index.flatMap { $0 >= 0 ? $0 : nil }
            )
        )
    }

    private static func predicate(_ json: [String: Any]) -> SemanticPredicate {
        SemanticPredicate(
            className: json.nonBlankString("className"),
            role: json.nonBlankString("role"),
            resourceId: json.nonBlankString("resourceId"),
            testId: json.nonBlankString("testId"),
            text: json.nonBlankString("text"),
            contentDescription: json.nonBlankString("contentDescription"),
            descendantText: json.nonBlankString("descendantText")
        )
    }
}

struct SemanticNodeSnapshot: Equatable {
    let nodeId: String
    let parentId: String?
    let className: String
    let role: String?
    let resourceId: String?
    let testId: String?
    let text: String?
    let contentDescription: String?
    let descendantText: [String]
    let indexInParent: Int
    let actionable: Bool
    let enabled: Bool
    let visible: Bool
    let bounds: CGRect?
}

enum SemanticMatchStatus: Equatable {
    case matched
    case notFound
    case ambiguous
}

struct SemanticMatchResult: Equatable {
    let status: SemanticMatchStatus
    let matchCount: Int
    let node: SemanticNodeSnapshot?
}

enum SemanticSelectorEvaluator {
    static func evaluate(
        nodes: [SemanticNodeSnapshot],
        selector: SemanticSelectorV1
    ) -> SemanticMatchResult {
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeId, $0) })
        let candidates = nodes.filter {
            $0.visible
                && $0.enabled
                && $0.actionable
                && matches($0, selector.node)
                && matchesAncestors($0, selector.ancestors, byId)
        }
        if let index = selector.indexAmongMatches {
            return candidates.indices.contains(index)
                ? SemanticMatchResult(status: .matched, matchCount: candidates.count, node: candidates[index])
                : SemanticMatchResult(status: .notFound, matchCount: candidates.count, node: nil)
        }
        switch candidates.count {
        case 0:
            return SemanticMatchResult(status: .notFound, matchCount: 0, node: nil)
        case 1:
            return SemanticMatchResult(status: .matched, matchCount: 1, node: candidates[0])
        default:
            return SemanticMatchResult(status: .ambiguous, matchCount: candidates.count, node: nil)
        }
    }

    static func normalize(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased() ?? ""
    }

    private static func matches(_ node: SemanticNodeSnapshot, _ predicate: SemanticPredicate) -> Bool {
        equals(predicate.className, node.className)
            && equals(predicate.role, node.role)
            && equals(predicate.resourceId, node.resourceId)
            && equals(predicate.testId, node.testId)
            && equals(predicate.text, node.text)
            && equals(predicate.contentDescription, node.contentDescription)
            && (predicate.descendantText == nil
                || node.descendantText.contains {
                    normalize($0) == normalize(predicate.descendantText)
                })
    }

    private static func matchesAncestors(
        _ node: SemanticNodeSnapshot,
        _ predicates: [SemanticPredicate],
        _ byId: [String: SemanticNodeSnapshot]
    ) -> Bool {
        var parent = node.parentId.flatMap { byId[$0] }
        var visited = Set<String>()
        for predicate in predicates {
            while let candidate = parent, !matches(candidate, predicate) {
                guard visited.insert(candidate.nodeId).inserted else { return false }
                parent = candidate.parentId.flatMap { byId[$0] }
            }
            guard let matched = parent, visited.insert(matched.nodeId).inserted else { return false }
            parent = matched.parentId.flatMap { byId[$0] }
        }
        return true
    }

    private static func equals(_ expected: String?, _ actual: String?) -> Bool {
        expected == nil || normalize(expected) == normalize(actual)
    }
}
