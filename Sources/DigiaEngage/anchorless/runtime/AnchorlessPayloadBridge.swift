// Module: anchorless/runtime
//
// The only place `Foundation`'s JSON representation meets the solver's
// platform-free `AnchorlessJSONValue`. Kept out of `anchorless/solver` so that
// ARCH-1 holds: the solver imports nothing.

import Foundation

internal enum AnchorlessPayloadBridge {

    /// Converts a `JSONSerialization` graph into the solver's value type.
    ///
    /// Returns `nil` only for a value JSON cannot express; a malformed *target* is
    /// not this function's business — the solver rejects it with a named code.
    internal static func value(from any: Any) -> AnchorlessJSONValue? {
        switch any {
        case is NSNull:
            return .null

        case let number as NSNumber:
            // `NSNumber` bridges Bool and numeric alike; distinguish by the
            // CoreFoundation type so a JSON `true` never becomes `1`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)

        case let string as String:
            return .string(string)

        case let array as [Any]:
            var values: [AnchorlessJSONValue] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = value(from: element) else { return nil }
                values.append(value)
            }
            return .array(values)

        case let dictionary as [String: Any]:
            var members: [String: AnchorlessJSONValue] = [:]
            members.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = value(from: element) else { return nil }
                members[key] = value
            }
            return .object(members)

        default:
            return nil
        }
    }

    /// Convenience for raw JSON bytes.
    internal static func value(fromJSON data: Data) -> AnchorlessJSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return value(from: any)
    }
}
