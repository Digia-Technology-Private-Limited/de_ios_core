import Foundation

/// Total, non-throwing `Any` → `JSONValue` for JSON-decoded payloads.
/// Returns nil only for values no JSON decoder can produce.
enum GamificationJSON {
    static func value(_ raw: Any) -> JSONValue? {
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            if double == double.rounded(), double >= -9_007_199_254_740_992,
               double <= 9_007_199_254_740_992
            {
                return .int(number.intValue)
            }
            return .double(double)
        }
        switch raw {
        case let string as String:
            return .string(string)
        case let array as [Any]:
            var values: [JSONValue] = []
            values.reserveCapacity(array.count)
            for item in array {
                guard let mapped = value(item) else { return nil }
                values.append(mapped)
            }
            return .array(values)
        case let object as [String: Any]:
            var values: [String: JSONValue] = [:]
            values.reserveCapacity(object.count)
            for (key, item) in object {
                guard let mapped = value(item) else { return nil }
                values[key] = mapped
            }
            return .object(values)
        case is NSNull:
            return .null
        default:
            return nil
        }
    }
}
