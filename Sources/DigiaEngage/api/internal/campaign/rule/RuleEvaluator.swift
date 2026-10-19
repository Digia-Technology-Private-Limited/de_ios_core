import Foundation

/// The moment that starts an evaluation.
enum RuleSignal {
    case appOpened
    case screenViewed(String)
    case event(String, [String: Any])
    case appForegrounded
    case anchorVisible(String)
    case slotVisible(String)

    /// Index key for this signal. Each ``RuleTrigger/listeningKeys`` entry that
    /// equals it receives this signal.
    var indexKey: String {
        switch self {
        case .appOpened: return "app_opened"
        case .screenViewed(let name): return "screen_viewed:\(name)"
        case .event(let name, _): return "event:\(name)"
        case .appForegrounded: return "app_foregrounded"
        case .anchorVisible(let key): return "anchor_visible:\(key)"
        case .slotVisible(let slot): return "slot_visible:\(slot)"
        }
    }

    /// The head of ``indexKey``: the name a log uses for the cause.
    var name: String {
        String(indexKey.split(separator: ":", maxSplits: 1).first ?? "")
    }
}

enum RuleVerdictKind: Equatable {
    case eligible
    case notTriggered
    case ineligible
}

struct RuleVerdict: Equatable {
    let kind: RuleVerdictKind
    let reason: IneligibleReason?
    /// For the log: the feature, the exception class, or the failed condition.
    let detail: String?

    static let eligible = RuleVerdict(kind: .eligible, reason: nil, detail: nil)
    static let notTriggered = RuleVerdict(kind: .notTriggered, reason: nil, detail: nil)

    static func ineligible(_ reason: IneligibleReason, _ detail: String? = nil) -> RuleVerdict {
        RuleVerdict(kind: .ineligible, reason: reason, detail: detail)
    }
}

/// Checks a rule's trigger and conditions against a signal. Pure; never throws.
enum RuleEvaluator {
    static func evaluate(
        _ rule: CampaignRule,
        _ signal: RuleSignal,
        attributes: [String: Any],
        device: [String: Any]
    ) -> RuleVerdict {
        switch rule {
        case .invalid(let invalid):
            return .ineligible(invalid.reason, invalid.detail)
        case .valid(let valid):
            if let broken = malformedLeaf(valid) {
                return .ineligible(.malformedRule, broken)
            }
            guard valid.triggers.contains(where: { triggered($0, signal) }) else {
                return .notTriggered
            }
            let values: [ValueSource: [String: Any]] = [
                .attribute: attributes,
                .device: device,
            ]
            return isTrue(valid.conditions, values: values)
                ? .eligible
                : .ineligible(.conditionFailed, failedCondition(valid.conditions, values: values))
        }
    }

    /// Whether `signal` matches `trigger`. Also used for wait cancels.
    static func matches(_ trigger: RuleTrigger, _ signal: RuleSignal) -> Bool {
        triggered(trigger, signal)
    }

    /// A rule built in code can hold a leaf the parser would reject. The
    /// evaluator rejects it as `malformed_rule` rather than comparing a value
    /// of the wrong type.
    private static func malformedLeaf(_ rule: ValidRule) -> String? {
        for trigger in rule.triggers {
            if case .event(_, let whereClause?) = trigger,
               let broken = malformedLeaf(whereClause)
            {
                return broken
            }
        }
        return malformedLeaf(rule.conditions)
    }

    private static func malformedLeaf(_ node: RuleCondition) -> String? {
        switch node {
        case .all(let children), .any(let children):
            for child in children {
                if let broken = malformedLeaf(child) { return broken }
            }
            return nil
        case .not(let child):
            return malformedLeaf(child)
        case .comparison(let leaf):
            return ruleValueFits(leaf) ? nil : "\(leaf.source.rawValue).\(leaf.key) value"
        }
    }

    private static func triggered(_ trigger: RuleTrigger, _ signal: RuleSignal) -> Bool {
        switch (trigger, signal) {
        case (.appOpened, .appOpened), (.appForegrounded, .appForegrounded):
            return true
        case (.screenViewed(let names), .screenViewed(let name)):
            return names.contains(name)
        case (.event(let name, let whereClause), .event(let eventName, let properties)):
            return name == eventName
                && (whereClause == nil || isTrue(whereClause!, values: [.prop: properties]))
        case (.anchorVisible(let keys), .anchorVisible(let key)):
            return keys.contains(key)
        case (.slotVisible(let slots), .slotVisible(let slot)):
            return slots.contains(slot)
        default:
            return false
        }
    }

    private static func isTrue(
        _ node: RuleCondition,
        values: [ValueSource: [String: Any]]
    ) -> Bool {
        switch node {
        case .all(let children): return children.allSatisfy { isTrue($0, values: values) }
        case .any(let children): return children.contains { isTrue($0, values: values) }
        case .not(let child): return !isTrue(child, values: values)
        case .comparison(let leaf):
            return compare(leaf, actual: values[leaf.source]?[leaf.key])
        }
    }

    /// The first comparison of a top-level `all` that fails, as `source.key`.
    private static func failedCondition(
        _ node: RuleCondition,
        values: [ValueSource: [String: Any]]
    ) -> String {
        let failed: RuleCondition
        if case .all(let children) = node {
            failed = children.first(where: { !isTrue($0, values: values) }) ?? node
        } else {
            failed = node
        }
        switch failed {
        case .comparison(let leaf): return "\(leaf.source.rawValue).\(leaf.key)"
        case .all: return "all"
        case .any: return "any"
        case .not: return "not"
        }
    }

    private static func compare(_ leaf: Comparison, actual: Any?) -> Bool {
        guard let actual, !(actual is NSNull) else { return false }
        let expected = leaf.value
        switch leaf.op {
        case .exists:
            return true
        case .eq:
            return equal(leaf, actual: actual, expected: expected)
        case .neq:
            return !equal(leaf, actual: actual, expected: expected)
        case .inList:
            guard let list = expected as? [Any] else { return false }
            return list.contains { ruleJSONEquals(actual, $0) }
        case .contains:
            if let haystack = actual as? String, let needle = expected as? String {
                return haystack.contains(needle)
            }
            if let list = actual as? [Any] {
                return list.contains { ruleJSONEquals($0, expected) }
            }
            return false
        case .gt, .gte, .lt, .lte:
            let order: Int?
            if leaf.isVersion {
                order = (actual as? String).flatMap { value in
                    (expected as? String).map { compareVersions(value, $0) }
                }
            } else {
                order = ruleNumber(actual).flatMap { number in
                    ruleNumber(expected).map { number == $0 ? 0 : (number > $0 ? 1 : -1) }
                }
            }
            guard let order, !isNaN(actual) else { return false }
            switch leaf.op {
            case .gt: return order > 0
            case .gte: return order >= 0
            case .lt: return order < 0
            default: return order <= 0
            }
        }
    }

    private static func isNaN(_ value: Any?) -> Bool {
        ruleNumber(value)?.isNaN ?? false
    }

    private static func equal(_ leaf: Comparison, actual: Any, expected: Any?) -> Bool {
        if leaf.isVersion {
            guard let actual = actual as? String, let expected = expected as? String else {
                return false
            }
            return compareVersions(actual, expected) == 0
        }
        return ruleJSONEquals(actual, expected)
    }

    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let left = versionParts(a)
        let right = versionParts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    private static func versionParts(_ version: String) -> [Int] {
        version.split(separator: ".", omittingEmptySubsequences: false).map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }
}
