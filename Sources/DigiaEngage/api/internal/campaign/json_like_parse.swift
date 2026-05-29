import Foundation

/// Lightweight `[String: Any]` readers mirroring Android `org.json` `opt*` semantics.
/// Used by the campaign model parsers ported from the Android SDK.
extension Dictionary where Key == String, Value == Any {
    func string(_ key: String, default fallback: String = "") -> String {
        self[key] as? String ?? fallback
    }

    /// Non-blank string or `nil`.
    func nonBlankString(_ key: String) -> String? {
        guard let value = self[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        self[key] as? Bool ?? fallback
    }

    func int(_ key: String, default fallback: Int) -> Int {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? NSNumber { return value.intValue }
        if let value = self[key] as? String, let parsed = Int(value) { return parsed }
        return fallback
    }

    func double(_ key: String, default fallback: Double) -> Double {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? NSNumber { return value.doubleValue }
        if let value = self[key] as? String, let parsed = Double(value) { return parsed }
        return fallback
    }

    func long(_ key: String, default fallback: Int64) -> Int64 {
        if let value = self[key] as? NSNumber { return value.int64Value }
        if let value = self[key] as? String, let parsed = Int64(value) { return parsed }
        return fallback
    }

    /// Optional numeric: `null` / missing / non-numeric => `nil`.
    func optionalDouble(_ key: String) -> Double? {
        guard let raw = self[key], !(raw is NSNull) else { return nil }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    /// Positive int (`> 0`) or `nil`.
    func positiveInt(_ key: String) -> Int? {
        guard let raw = self[key], !(raw is NSNull) else { return nil }
        let value = (raw as? NSNumber)?.intValue
        return value.flatMap { $0 > 0 ? $0 : nil }
    }

    func object(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    /// Array of objects, skipping any non-object elements.
    func objectArray(_ key: String) -> [[String: Any]] {
        (self[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// Array of non-blank strings.
    func stringArray(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { element -> String? in
            guard let string = element as? String, !string.isEmpty else { return nil }
            return string
        } ?? []
    }
}
