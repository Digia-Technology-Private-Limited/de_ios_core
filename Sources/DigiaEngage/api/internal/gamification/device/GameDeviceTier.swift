import Foundation

/// A fact value or rule operand. A typed enum keeps facts and rules Equatable and Sendable.
enum TierOperand: Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case list([TierOperand])
    /// A JSON value no operator compares (an object, or null inside a list).
    case other

    /// nil for nil or NSNull. A JSON boolean arrives as NSNumber, so it is told apart by CFBoolean.
    static func from(_ raw: Any?) -> TierOperand? {
        switch raw {
        case nil, is NSNull:
            return nil
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let a as [Any]:
            return .list(a.map { TierOperand.from($0) ?? .other })
        default:
            return .other
        }
    }

    /// A JSON-serialisable value for the bridge payload.
    var json: Any {
        switch self {
        case let .number(d): return d
        case let .bool(b): return b
        case let .string(s): return s
        case let .list(l): return l.map(\.json)
        case .other: return NSNull()
        }
    }
}

/// One rule condition: `fact` compared with every operator in `ops` (all must hold).
struct TierCondition: Equatable, Sendable {
    let fact: String
    let ops: [String: TierOperand]
}

/// A tier and the conditions that select it; `any` needs one true, `all` needs every one.
struct TierRule: Equatable, Sendable {
    let tier: String
    let any: [TierCondition]?
    let all: [TierCondition]?
}

/// `gamification.deviceTier` from the SDK config: how a device is placed in `high`, `mid` or
/// `low`. The defaults mirror the backend's `DEFAULT_DEVICE_TIER`
/// (`backend/src/services/digia-engage/sdk/gamificationConfig.ts`), which is the source of truth.
struct DeviceTierConfig: Equatable, Sendable {
    let weights: [String: Double]
    let rules: [TierRule]
    let fallback: String

    static let tiers: Set<String> = ["high", "mid", "low"]

    private static func eq(_ fact: String, _ value: TierOperand) -> TierCondition {
        TierCondition(fact: fact, ops: ["eq": value])
    }

    private static func gte(_ fact: String, _ value: Double) -> TierCondition {
        TierCondition(fact: fact, ops: ["gte": .number(value)])
    }

    static let `default` = DeviceTierConfig(
        weights: ["cpuLevel": 3, "memoryLevel": 3, "thermalLevel": 2, "batteryLevel": 1],
        rules: [
            TierRule(
                tier: "low",
                any: [
                    eq("isLowRamDevice", .bool(true)),
                    eq("isSystemLowOnMemory", .bool(true)),
                    eq("isPowerSaveMode", .bool(true)),
                    eq("isReduceMotionEnabled", .bool(true)),
                    eq("thermalLevel", .number(1)),
                    eq("memoryLevel", .number(1)),
                    eq("cpuLevel", .number(1)),
                ],
                all: nil
            ),
            TierRule(tier: "high", any: nil, all: [gte("performanceScore", 3), gte("batteryLevel", 2)]),
            TierRule(tier: "mid", any: nil, all: [gte("performanceScore", 2)]),
        ],
        fallback: "low"
    )

    private static let numericOps: Set<String> = ["lt", "lte", "gt", "gte"]

    /// The config, or `default` when `json` is missing or malformed anywhere: a bad value falls
    /// back whole, never half-applies, and never throws. An operator this SDK does not know is
    /// kept and evaluates false, so a newer rule never matches on an older SDK.
    static func parse(_ json: [String: Any]?) -> DeviceTierConfig {
        guard let json, let config = parseOrNil(json) else { return .default }
        return config
    }

    private static func parseOrNil(_ json: [String: Any]) -> DeviceTierConfig? {
        guard let weightsJson = json["weights"] as? [String: Any] else { return nil }
        var weights: [String: Double] = [:]
        for (key, raw) in weightsJson {
            guard let w = finite(raw), w >= 0 else { return nil }
            weights[key] = w
        }
        guard weights.values.contains(where: { $0 > 0 }) else { return nil }

        guard let rulesJson = json["rules"] as? [Any] else { return nil }
        var rules: [TierRule] = []
        for raw in rulesJson {
            guard let r = rule(raw) else { return nil }
            rules.append(r)
        }
        guard let fallback = json["fallback"] as? String, tiers.contains(fallback) else { return nil }
        return DeviceTierConfig(weights: weights, rules: rules, fallback: fallback)
    }

    private static func rule(_ raw: Any) -> TierRule? {
        guard let json = raw as? [String: Any],
              let tier = json["tier"] as? String, tiers.contains(tier) else { return nil }
        let hasAny = json.keys.contains("any")
        let hasAll = json.keys.contains("all")
        guard hasAny || hasAll else { return nil }
        var any: [TierCondition]?
        var all: [TierCondition]?
        if hasAny {
            guard let c = conditions(json["any"] as Any) else { return nil }
            any = c
        }
        if hasAll {
            guard let c = conditions(json["all"] as Any) else { return nil }
            all = c
        }
        return TierRule(tier: tier, any: any, all: all)
    }

    private static func conditions(_ raw: Any) -> [TierCondition]? {
        guard let array = raw as? [Any], !array.isEmpty else { return nil }
        var result: [TierCondition] = []
        for item in array {
            guard let c = condition(item) else { return nil }
            result.append(c)
        }
        return result
    }

    private static func condition(_ raw: Any) -> TierCondition? {
        guard let json = raw as? [String: Any], let fact = json["fact"] as? String else { return nil }
        var ops: [String: TierOperand] = [:]
        for (op, operand) in json where op != "fact" {
            switch op {
            case "eq":
                switch TierOperand.from(operand) {
                case let .string(s): ops[op] = .string(s)
                case let .bool(b): ops[op] = .bool(b)
                case let .number(d) where d.isFinite: ops[op] = .number(d)
                default: return nil
                }
            case "in":
                guard case let .list(items)? = TierOperand.from(operand), !items.isEmpty else { return nil }
                ops[op] = .list(items)
            case _ where numericOps.contains(op):
                guard let d = finite(operand) else { return nil }
                ops[op] = .number(d)
            default:
                // Unknown operator: kept with any value (null included) and evaluates false.
                ops[op] = TierOperand.from(operand) ?? .other
            }
        }
        guard !ops.isEmpty else { return nil }
        return TierCondition(fact: fact, ops: ops)
    }

    /// A finite non-boolean number, else nil.
    private static func finite(_ raw: Any?) -> Double? {
        guard case let .number(d)? = TierOperand.from(raw), d.isFinite else { return nil }
        return d
    }
}

/// Places a device in a tier from its facts, using the config the backend last sent.
enum GameDeviceTier {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _config = DeviceTierConfig.default

    static var config: DeviceTierConfig { lock.withLock { _config } }

    static func applyConfig(_ config: DeviceTierConfig) {
        lock.withLock { _config = config }
    }

    /// `facts` plus `performanceScore`: the weighted mean of the levels that are known (> 0) and
    /// weighted (> 0), or 0 when none are.
    static func scored(_ facts: [String: TierOperand], config: DeviceTierConfig? = nil) -> [String: TierOperand] {
        let config = config ?? self.config
        var sum = 0.0
        var weight = 0.0
        for (key, w) in config.weights {
            guard case let .number(level)? = facts[key], w > 0, level > 0 else { continue }
            sum += w * level
            weight += w
        }
        var result = facts
        result["performanceScore"] = .number(weight > 0 ? sum / weight : 0)
        return result
    }

    /// The tier of the first rule that matches `facts`, else the config's fallback.
    static func evaluate(_ facts: [String: TierOperand], config: DeviceTierConfig? = nil) -> String {
        let config = config ?? self.config
        return config.rules.first { matches($0, facts) }?.tier ?? config.fallback
    }

    private static func matches(_ rule: TierRule, _ facts: [String: TierOperand]) -> Bool {
        let anyOk = rule.any.map { $0.contains { holds($0, facts) } } ?? true
        let allOk = rule.all.map { $0.allSatisfy { holds($0, facts) } } ?? true
        return anyOk && allOk
    }

    /// A missing fact, a type mismatch, or an unknown operator is false.
    private static func holds(_ condition: TierCondition, _ facts: [String: TierOperand]) -> Bool {
        guard let value = facts[condition.fact] else { return false }
        return condition.ops.allSatisfy { op, operand in
            switch op {
            case "eq":
                return same(value, operand)
            case "in":
                guard case let .list(items) = operand else { return false }
                return items.contains { same(value, $0) }
            case "lt", "lte", "gt", "gte":
                guard case let .number(a) = value, case let .number(b) = operand else { return false }
                switch op {
                case "lt": return a < b
                case "lte": return a <= b
                case "gt": return a > b
                default: return a >= b
                }
            default:
                return false
            }
        }
    }

    private static func same(_ a: TierOperand, _ b: TierOperand) -> Bool {
        switch (a, b) {
        case let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        default: return false
        }
    }
}
