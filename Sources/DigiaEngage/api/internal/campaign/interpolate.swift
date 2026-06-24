import Foundation

// MARK: - Identifier grammar (D22′: lowercase only)

private let identifierPattern = try! NSRegularExpression(pattern: #"^[a-z][a-z0-9_]*$"#)

private func isIdentifier(_ s: String) -> Bool {
    let r = NSRange(s.startIndex..., in: s)
    return identifierPattern.firstMatch(in: s, range: r) != nil
}

// MARK: - Placeholder pattern ({{ ... }})

private let placeholderPattern = try! NSRegularExpression(pattern: #"\{\{([\s\S]*?)\}\}"#)

// MARK: - Main interpolation function

func interpolate(_ text: String, context: VariableContext?) -> String {
    guard text.contains("{{") else { return text }

    let ns = text as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    let matches = placeholderPattern.matches(in: text, range: fullRange)

    var result = ""
    var lastEnd = text.startIndex

    for match in matches {
        guard let matchRange = Range(match.range, in: text),
              let innerRange = Range(match.range(at: 1), in: text)
        else { continue }

        result += text[lastEnd..<matchRange.lowerBound]

        let inner = String(text[innerRange]).trimmingCharacters(in: .whitespaces)

        if isIdentifier(inner) {
            // Single identifier — plain substitution
            result += context?.values[inner] ?? ""
        } else if let ctx = context {
            // Arithmetic expression
            result += evalArithmetic(inner, context: ctx) ?? ""
        }

        lastEnd = matchRange.upperBound
    }

    result += text[lastEnd...]
    return result
}

// MARK: - Backward-compat shim (flat [String: String]? callers)

func interpolate(_ text: String, variables: [String: String]?) -> String {
    guard let variables, !variables.isEmpty else { return text }
    let context = VariableContext(values: variables, types: [:])
    return interpolate(text, context: context)
}
