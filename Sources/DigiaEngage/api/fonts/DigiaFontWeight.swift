import SwiftUI

/// Converts dashboard font-weight data at the SwiftUI rendering boundary.
enum DigiaFontWeight {
    static func value(_ value: Any?, default fallback: Int = 400) -> Int {
        numericValue(value) ?? fallback
    }

    static func parse(_ value: String?, default fallback: Font.Weight = .regular) -> Font.Weight {
        optional(value) ?? fallback
    }

    static func parse(_ value: Int?, default fallback: Font.Weight = .regular) -> Font.Weight {
        guard let value, (100...900).contains(value) else { return fallback }
        return switch value {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    static func optional(_ value: Any?) -> Font.Weight? {
        numericValue(value).map { parse($0) }
    }

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
