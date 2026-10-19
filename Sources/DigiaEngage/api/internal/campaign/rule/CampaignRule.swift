import Foundation

/// Sent on `getCampaignBundle`. The backend sends only campaigns whose schema
/// version is at or below ``campaignSchemaVersion``.
let campaignSchemaVersionHeader = "x-digia-campaign-schema-version"

/// The highest campaign schema version this SDK handles. Raise it only when
/// this SDK handles every part of the next version (spec §3.6).
let campaignSchemaVersion = 2

let maxRuleDepth = 6

/// Why a rule makes its campaign ineligible. `wire` is the decision reason.
enum IneligibleReason: String, Equatable {
    case unsupportedFeature = "unsupported_feature"
    case malformedRule = "malformed_rule"
    case conditionFailed = "condition_failed"

    var wire: String { rawValue }
}

enum RuleOperator: String, Equatable {
    case eq, neq, contains, gt, gte, lt, lte, exists
    case inList = "in"
}

enum ValueSource: String, Equatable {
    case attribute, device, prop
}

let ruleDeviceKeys: Set<String> = [
    "platform",
    "os_version",
    "app_version",
    "sdk_version",
    "locale",
    "app_opens",
]
private let versionKeys: Set<String> = ["os_version", "app_version", "sdk_version"]

// MARK: - Conditions

indirect enum RuleCondition: Equatable {
    case all([RuleCondition])
    case any([RuleCondition])
    case not(RuleCondition)
    case comparison(Comparison)

    static func == (lhs: RuleCondition, rhs: RuleCondition) -> Bool {
        switch (lhs, rhs) {
        case let (.all(a), .all(b)), let (.any(a), .any(b)):
            return a == b
        case let (.not(a), .not(b)):
            return a == b
        case let (.comparison(a), .comparison(b)):
            return a == b
        default:
            return false
        }
    }
}

/// One `attribute`, `device` or `prop` comparison.
struct Comparison: Equatable {
    let source: ValueSource
    let key: String
    let op: RuleOperator
    let value: Any?

    /// A `device` version key, compared part by part.
    var isVersion: Bool {
        source == .device && versionKeys.contains(key)
    }

    static func == (lhs: Comparison, rhs: Comparison) -> Bool {
        lhs.source == rhs.source && lhs.key == rhs.key && lhs.op == rhs.op
            && ruleJSONEquals(lhs.value, rhs.value)
    }
}

// MARK: - Triggers

enum RuleTrigger: Equatable {
    case appOpened
    case screenViewed(names: [String])
    case event(name: String, where: RuleCondition?)
    case appForegrounded
    case anchorVisible(keys: [String])
    case slotVisible(slots: [String])

    /// Index keys this trigger listens for. Each entry must equal some
    /// ``RuleSignal/indexKey``, or no signal ever reaches it.
    var listeningKeys: [String] {
        switch self {
        case .appOpened: return ["app_opened"]
        case .screenViewed(let names): return names.map { "screen_viewed:\($0)" }
        case .event(let name, _): return ["event:\(name)"]
        case .appForegrounded: return ["app_foregrounded"]
        case .anchorVisible(let keys): return keys.map { "anchor_visible:\($0)" }
        case .slotVisible(let slots): return slots.map { "slot_visible:\($0)" }
        }
    }
}

// MARK: - Waits

enum CancelCondition: Equatable {
    /// An `event` or `screen_viewed` that cancels the wait when it matches.
    case onSignal(RuleTrigger)
    /// `screen_left`. With `names`, the user leaves when the screen is not one
    /// of them. Without, when it differs from the screen at the wait start.
    case onScreenLeft(names: [String]?)
}

/// `delay`: show `ms` after the trigger unless a `cancels` item matches.
struct RuleWait: Equatable {
    let ms: Int
    let cancels: [CancelCondition]
}

// MARK: - Rules

enum CampaignRule: Equatable {
    case valid(ValidRule)
    case invalid(InvalidRule)

    var priority: Double? {
        if case .valid(let rule) = self { return rule.priority }
        return nil
    }
}

/// The higher number wins. Equal priorities go to the campaign key that sorts
/// first (see `pickCampaign`).
struct ValidRule: Equatable {
    let priority: Double
    /// True when the wire had no valid `priority` and ``defaultPriority`` is used.
    let priorityDefaulted: Bool
    let triggers: [RuleTrigger]
    let conditions: RuleCondition
    /// Nil when the campaign shows at the trigger.
    let wait: RuleWait?
}

/// A rule this SDK cannot evaluate. `reason` is `unsupported_feature` or
/// `malformed_rule`; `detail` says what was wrong, for the log only.
struct InvalidRule: Equatable {
    let reason: IneligibleReason
    let detail: String
}

/// The priority of a campaign whose rule has none, or an invalid one.
let defaultPriority: Double = 600

private struct RuleRejected: Error {
    let reason: IneligibleReason
    let detail: String
}

/// Parses a `campaign_rule` payload. Never throws: a rule it cannot use becomes
/// an ``CampaignRule/invalid`` carrying the reason the decision needs.
func parseRule(_ json: Any?) -> CampaignRule {
    do {
        return try parseEnvelope(json)
    } catch let rejected as RuleRejected {
        return .invalid(InvalidRule(reason: rejected.reason, detail: rejected.detail))
    } catch {
        return .invalid(InvalidRule(reason: .malformedRule, detail: "\(error)"))
    }
}

private func malformed(_ detail: String) throws -> Never {
    throw RuleRejected(reason: .malformedRule, detail: detail)
}

/// A type this SDK doesn't know, `@N` names included, skips the campaign.
private func unknownType(_ type: Any?, _ place: String) throws -> Never {
    if let string = type as? String {
        throw RuleRejected(reason: .unsupportedFeature, detail: string)
    }
    try malformed("\(String(describing: type)) is not a \(place)")
}

private func parseEnvelope(_ json: Any?) throws -> CampaignRule {
    guard let json = json as? [String: Any] else { try malformed("rule is not an object") }
    // A missing or invalid priority degrades to the default, never drops the rule.
    let priority = json["priority"]
    let validPriority = ruleJSONNumber(priority).map { $0.isFinite } ?? false
    guard let trigger = json["trigger"] as? [String: Any],
          let anyTriggers = trigger["any"] as? [Any]
    else { try malformed("trigger has no any list") }
    return .valid(
        ValidRule(
            priority: validPriority ? ruleJSONNumber(priority)! : defaultPriority,
            priorityDefaulted: !validPriority,
            triggers: try anyTriggers.map(parseTrigger),
            conditions: try parseNode(json["conditions"], depth: 1, leaves: ["attribute", "device"]),
            wait: try json["wait"].flatMap { raw -> RuleWait? in
                if raw is NSNull { return nil }
                return try parseWait(raw)
            }
        ))
}

/// The longest delay kept, about 31,700 years.
private let maxDelayMs = 1e15

private func parseWait(_ json: Any?) throws -> RuleWait {
    guard let json = json as? [String: Any] else { try malformed("wait is not an object") }
    guard json["type"] as? String == "delay" else { try unknownType(json["type"], "wait") }
    guard let ms = ruleJSONNumber(json["ms"]), ms.isFinite, ms >= 1,
          ms == ms.rounded(.towardZero) else {
        try malformed("delay ms \(String(describing: json["ms"]))")
    }
    let cancel = json["cancel"]
    let any: [Any]
    switch cancel {
    case nil, is NSNull:
        any = []
    case let object as [String: Any]:
        guard let list = object["any"] as? [Any] else { try malformed("delay cancel has no any list") }
        any = list
    default:
        try malformed("delay cancel has no any list")
    }
    // A delay past any real session keeps its meaning (the wait never ends) and
    // cannot trap `Int(_:)` or overflow the end-time sum in `Waits`.
    return RuleWait(ms: Int(min(ms, maxDelayMs)), cancels: try any.map(parseCancel))
}

private func parseCancel(_ json: Any?) throws -> CancelCondition {
    guard let json = json as? [String: Any] else { try malformed("cancel is not an object") }
    switch json["type"] as? String {
    case "event", "screen_viewed":
        return .onSignal(try parseTrigger(json))
    case "screen_left":
        if let names = json["names"], !(names is NSNull) {
            guard let list = names as? [Any], !list.isEmpty,
                  list.allSatisfy({ ($0 as? String).map { !$0.isEmpty } ?? false })
            else { try malformed("screen_left names") }
            return .onScreenLeft(names: list.compactMap { $0 as? String })
        }
        return .onScreenLeft(names: nil)
    default:
        try unknownType(json["type"], "cancel")
    }
}

private func parseTrigger(_ json: Any?) throws -> RuleTrigger {
    guard let json = json as? [String: Any] else { try malformed("trigger is not an object") }
    switch json["type"] as? String {
    case "app_opened":
        return .appOpened
    case "screen_viewed":
        return .screenViewed(names: try nameList(json["names"], "screen_viewed names"))
    case "event":
        guard let name = json["name"] as? String, !name.isEmpty else { try malformed("event name") }
        let whereClause = json["where"]
        return .event(
            name: name,
            where: try (whereClause == nil || whereClause is NSNull)
                ? nil
                : parseNode(whereClause, depth: 1, leaves: ["prop"])
        )
    case "app_foregrounded":
        return .appForegrounded
    case "anchor_visible":
        return .anchorVisible(keys: try nameList(json["keys"], "anchor_visible keys"))
    case "slot_visible":
        return .slotVisible(slots: try nameList(json["slots"], "slot_visible slots"))
    default:
        try unknownType(json["type"], "trigger")
    }
}

private func nameList(_ value: Any?, _ detail: String) throws -> [String] {
    guard let list = value as? [Any], !list.isEmpty,
          list.allSatisfy({ ($0 as? String).map { !$0.isEmpty } ?? false })
    else { try malformed(detail) }
    return list.compactMap { $0 as? String }
}

private let knownLeaves: Set<String> = ["attribute", "device", "prop"]

/// `depth` is 1 at the root of `conditions` or `where`.
private func parseNode(_ json: Any?, depth: Int, leaves: Set<String>) throws -> RuleCondition {
    guard depth <= maxRuleDepth else { try malformed("depth over \(maxRuleDepth)") }
    guard let json = json as? [String: Any] else { try malformed("node is not an object") }
    let shape = ["all", "any", "not", "type"].filter { json.keys.contains($0) }
    guard shape.count == 1 else {
        try malformed("node shape \(json.keys.sorted())")
    }
    switch shape[0] {
    case "all":
        return .all(try parseChildren(json["all"], depth: depth, leaves: leaves))
    case "any":
        return .any(try parseChildren(json["any"], depth: depth, leaves: leaves))
    case "not":
        return .not(try parseNode(json["not"], depth: depth + 1, leaves: leaves))
    default:
        guard let type = json["type"] as? String else { try unknownType(json["type"], "condition") }
        if leaves.contains(type) { return .comparison(try parseComparison(json, type: type)) }
        if knownLeaves.contains(type) { try malformed("\(type) leaf here") }
        try unknownType(type, "condition")
    }
}

private func parseChildren(_ json: Any?, depth: Int, leaves: Set<String>) throws -> [RuleCondition] {
    guard let list = json as? [Any] else { try malformed("children is not a list") }
    return try list.map { try parseNode($0, depth: depth + 1, leaves: leaves) }
}

private func parseComparison(_ json: Any?, type: String) throws -> Comparison {
    guard let json = json as? [String: Any] else { try malformed("leaf is not an object") }
    guard json["type"] as? String == type else { try unknownType(json["type"], type) }
    let source: ValueSource =
        switch type {
        case "attribute": .attribute
        case "device": .device
        default: .prop
        }
    guard let key = json["key"] as? String, !key.isEmpty else { try malformed("\(type) key") }
    if source == .device, !ruleDeviceKeys.contains(key) {
        try malformed("device key \(key)")
    }
    guard let rawOp = json["op"] as? String, let op = RuleOperator(rawValue: rawOp) else {
        try unknownType(json["op"], "op")
    }
    let leaf = Comparison(source: source, key: key, op: op, value: json["value"])
    guard ruleValueFits(leaf) else {
        try malformed("\(type) \(key) \(rawOp) value")
    }
    return leaf
}

func ruleValueFits(_ leaf: Comparison) -> Bool {
    let value = leaf.value
    switch leaf.op {
    case .exists:
        return true
    case .inList:
        return value is [Any]
    case .gt, .gte, .lt, .lte:
        return leaf.isVersion ? value is String : ruleJSONNumber(value) != nil
    case .eq, .neq:
        if leaf.isVersion { return value is String }
        return value != nil && !(value is [String: Any]) && !(value is NSNull)
    case .contains:
        return value != nil && !(value is [String: Any]) && !(value is [Any]) && !(value is NSNull)
    }
}

// MARK: - JSON value helpers

/// JSON numbers arrive bridged as `NSNumber`; a JSON boolean is an `NSNumber`
/// too, so it must be ruled out before every numeric read.
func ruleIsBool(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

/// A JSON number only: never a boolean, never a numeric string.
func ruleJSONNumber(_ value: Any?) -> Double? {
    guard let value, !ruleIsBool(value) else { return nil }
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
}

/// A JSON number, or a decimal string. Used where the contract accepts a
/// numeric string for the *actual* value (e.g. a device version), never for
/// authoring a rule value.
func ruleNumber(_ value: Any?) -> Double? {
    if let number = ruleJSONNumber(value) { return number }
    if let string = value as? String {
        let pattern = #"^-?\d+(\.\d+)?$"#
        guard string.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return Double(string)
    }
    return nil
}

/// Same JSON type and equal. Numbers compare numerically.
func ruleJSONEquals(_ a: Any?, _ b: Any?) -> Bool {
    if a == nil || a is NSNull { return b == nil || b is NSNull }
    if b == nil || b is NSNull { return false }
    if let aNumber = ruleJSONNumber(a), let bNumber = ruleJSONNumber(b) {
        return aNumber == bNumber
    }
    if ruleIsBool(a) || ruleIsBool(b) {
        guard ruleIsBool(a), ruleIsBool(b) else { return false }
        return (a as? Bool) == (b as? Bool)
    }
    if let aString = a as? String, let bString = b as? String { return aString == bString }
    if let aList = a as? [Any], let bList = b as? [Any] {
        guard aList.count == bList.count else { return false }
        return zip(aList, bList).allSatisfy { ruleJSONEquals($0, $1) }
    }
    return false
}
