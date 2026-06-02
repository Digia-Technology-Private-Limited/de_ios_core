import Foundation

private let placeholderPattern = try! NSRegularExpression(
    pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}"#
)

func interpolate(_ text: String, variables: [String: String]?) -> String {
    guard let variables, !variables.isEmpty else { return text }
    let fullRange = NSRange(text.startIndex..., in: text)
    let matches = placeholderPattern.matches(in: text, range: fullRange)
    var result = ""
    var lastEnd = text.startIndex
    for match in matches {
        guard let matchRange = Range(match.range, in: text),
              let nameRange = Range(match.range(at: 1), in: text) else { continue }
        result += text[lastEnd..<matchRange.lowerBound]
        result += variables[String(text[nameRange])] ?? ""
        lastEnd = matchRange.upperBound
    }
    result += text[lastEnd...]
    return result
}
