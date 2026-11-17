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

    /// Whether `key` is absent or JSON `null`.
    func isAbsent(_ key: String) -> Bool {
        self[key] == nil || self[key] is NSNull
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

    /// Positive int (`> 0`) or `nil`.
    func positiveInt(_ key: String) -> Int? {
        guard let raw = self[key], !(raw is NSNull) else { return nil }
        let value = (raw as? NSNumber)?.intValue
        return value.flatMap { $0 > 0 ? $0 : nil }
    }

    /// A frequency cap as a whole number >= 1, or `nil` (no cap). Accepts a number or a
    /// numeric string (" 2 ", "3.0"); zero, negatives, fractions, booleans, junk and values
    /// past a 32-bit int all mean no cap. Same rule on every stack.
    func capInt(_ key: String) -> Int? {
        let text: String
        if let number = self[key] as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            text = number.stringValue
        } else if let string = self[key] as? String {
            text = string
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        func isDigits(_ part: Substring, only: Character? = nil) -> Bool {
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber && (only == nil || $0 == only) }
        }
        guard parts.count <= 2, isDigits(parts[0]), parts.count == 1 || isDigits(parts[1], only: "0"),
              let value = Int(parts[0]), value >= 1, value <= Int(Int32.max)
        else { return nil }
        return value
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
