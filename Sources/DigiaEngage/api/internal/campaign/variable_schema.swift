import Foundation

// MARK: - Variable schema + raw-JSON normalisation
//
// A `VariableSchema` is one declared campaign variable: its name, its type
// ("string" | "number") and the fallbackValue used when CEP supplies nothing.

struct VariableSchema: Equatable {
    let name: String
    let type: String        // "string" | "number" | "bool"
    let fallbackValue: String
    /// `false` when no fallback was authored. An authored empty string is a fallback.
    var hasFallback = true

    /// Resolves `raw` through runtime value → fallback → `""`, always as text of this
    /// type. A value that does not fit the type is skipped like an empty one.
    func resolve(_ raw: Any?) -> String {
        typed(raw) ?? typed(hasFallback ? fallbackValue : nil) ?? ""
    }

    /// `value` as text of this type, or nil when it is empty or does not fit.
    private func typed(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        switch type {
        case "number":
            let number: Double?
            if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                number = n.doubleValue
            } else if value is NSNumber {
                number = nil
            } else {
                number = Double(dartText(value).trimmingCharacters(in: .whitespaces))
            }
            guard let number, number.isFinite else { return nil }
            return formatCopyNumber(number)
        case "bool":
            let lower = dartText(value).trimmingCharacters(in: .whitespaces).lowercased()
            return lower == "true" || lower == "false" ? lower : nil
        default:
            let text = dartText(value)
            return text.isEmpty ? nil : text
        }
    }
}

/// `value` as plain text: booleans print `true`/`false`, a list prints `[a, b]`.
func dartText(_ value: Any) -> String {
    switch value {
    case let string as String:
        return string
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        return number.stringValue
    case let list as [Any]:
        return "[" + list.map(dartText).joined(separator: ", ") + "]"
    default:
        return "\(value)"
    }
}

/// Prints `value` for copy: at most four decimals, no trailing zeros, `""` for a
/// non-finite value.
func formatCopyNumber(_ value: Double) -> String {
    guard value.isFinite else { return "" }
    let rounded = (value * 10000).rounded() / 10000
    var result = String(format: "%.4f", rounded)
    if result.contains(".") {
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
    }
    return result
}

/// The two sources a context variable reads from, by token prefix.
let userNamespace = "user"
let eventNamespace = "event"

/// Parses one raw entry from `templateConfig.contextVariables` into a declaration named
/// by its token, e.g. `user.age`. Returns nil when the namespace or key is missing or
/// unusable.
///
/// A missing or unknown type is inferred from a typed fallback, so a number or bool
/// token still prints as one; anything else is text. With no fallback, a number falls
/// back to `0` and a bool to `false`, so copy never shows a gap where the author
/// expected a value.
func normalizeContextVariable(_ entry: [String: Any]) -> VariableSchema? {
    guard let namespace = entry["namespace"] as? String,
          namespace == userNamespace || namespace == eventNamespace,
          let key = entry["key"] as? String,
          key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    else { return nil }
    let fallback = entry["fallbackValue"]
    let isBool = (fallback as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    let type: String
    switch entry["type"] as? String {
    case "number": type = "number"
    case "bool": type = "bool"
    case "string": type = "string"
    default: type = isBool ? "bool" : (fallback is NSNumber ? "number" : "string")
    }
    let authored = (fallback.flatMap { $0 is NSNull ? nil : dartText($0) }) ?? ""
    let defaultText = type == "number" ? "0" : type == "bool" ? "false" : ""
    return VariableSchema(
        name: "\(namespace).\(key)",
        type: type,
        fallbackValue: authored.isEmpty ? defaultText : authored
    )
}

/// Normalises a raw variable definition into a `VariableSchema` (D29).
func normalizeVariable(name: String, type rawType: String?, fallbackValue: String?, sampleValue: String?) -> VariableSchema {
    VariableSchema(
        name: name,
        type: rawType == "number" ? "number" : "string",
        fallbackValue: fallbackValue ?? sampleValue ?? "",
        hasFallback: (fallbackValue ?? sampleValue) != nil
    )
}
