import Foundation

/// Decodes dashboard font weights into the SDK's numeric domain representation.
enum DigiaFontWeight {
    static func value(_ value: Any?, default fallback: Int = 400) -> Int {
        numericValue(value) ?? fallback
    }

    static func optional(_ value: Any?) -> Int? { numericValue(value) }

    private static func numericValue(_ raw: Any?) -> Int? {
        let value: String?
        if let raw = raw as? String {
            value = raw
        } else if let raw = raw as? NSNumber {
            value = raw.stringValue
        } else {
            value = nil
        }
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return nil }

        let numeric: Int?
        if let parsed = Int(normalized) {
            numeric = parsed
        } else {
            numeric = switch normalized {
            case "thin": 100
            case "extralight", "extra_light": 200
            case "light": 300
            case "normal", "regular": 400
            case "medium": 500
            case "semibold", "semi_bold": 600
            case "bold": 700
            case "extrabold", "extra_bold": 800
            case "heavy", "black": 900
            default: nil
            }
        }
        return numeric.flatMap { (100...900).contains($0) ? $0 : nil }
    }
}
