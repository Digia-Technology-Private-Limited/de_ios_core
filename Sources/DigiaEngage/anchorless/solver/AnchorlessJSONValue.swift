// Module: anchorless/solver
//
// A platform-free JSON value. `anchorless/solver` "depends on nothing at all and
// contains no platform type" (native runtime contract §1), so the solver parses
// this value rather than `Foundation`'s `Any`/`NSNumber` graph. Bridging from
// `JSONSerialization` output lives in `anchorless/runtime`, outside the solver.
//
// Deliberately NOT `Codable`: `Decodable` synthesis would pull the solver towards
// `Foundation`'s decoders, and the solver's parse must stay strict and explicit so
// that every rejection maps to a named `AnchorlessFailure` code.

/// A parsed JSON value with no platform or Foundation dependency.
internal enum AnchorlessJSONValue: Equatable, Sendable {
    case object([String: AnchorlessJSONValue])
    case array([AnchorlessJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

extension AnchorlessJSONValue {
    internal var objectValue: [String: AnchorlessJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    internal var arrayValue: [AnchorlessJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    internal var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// Numbers only. A JSON `true` is not `1`, and a numeric string is not a number:
    /// the solver never coerces across types.
    internal var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    internal var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    internal var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Member lookup. An explicit JSON `null` reads as absent, which is what the
    /// wire shape means by an optional field.
    internal subscript(key: String) -> AnchorlessJSONValue? {
        guard case let .object(members) = self else { return nil }
        guard let member = members[key], !member.isNull else { return nil }
        return member
    }

    /// True when the key is physically present, `null` included. Needed to tell
    /// "`crop` absent" from "`crop` delivered as null" where the contract forbids
    /// the field being present at all.
    internal func hasMember(_ key: String) -> Bool {
        guard case let .object(members) = self else { return false }
        return members[key] != nil
    }
}
