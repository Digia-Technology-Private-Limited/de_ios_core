import SwiftUI

/// The font-weight contract shared by every Digia Engage renderer.
enum DigiaFontWeight {
    static let supportedValues = [400, 500, 600, 700]

    static func normalized(_ weight: Font.Weight) -> Font.Weight {
        fromNumeric(normalized(weight.numericValue))
    }

    static func normalized(_ value: Int) -> Int {
        supportedValues.min { lhs, rhs in
            let lhsDistance = abs(lhs - value)
            let rhsDistance = abs(rhs - value)
            return lhsDistance == rhsDistance ? lhs > rhs : lhsDistance < rhsDistance
        } ?? 400
    }

    static func normalized(_ value: String, default fallback: Font.Weight) -> Font.Weight {
        if let numeric = Int(value) {
            return fromNumeric(normalized(numeric))
        }
        switch value.lowercased() {
        case "regular": return .regular
        case "medium": return .medium
        case "semibold", "semi_bold": return .semibold
        case "bold": return .bold
        default: return normalized(fallback)
        }
    }

    private static func fromNumeric(_ value: Int) -> Font.Weight {
        switch value {
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        default: return .regular
        }
    }
}

extension Font.Weight {
    var numericValue: Int {
        switch self {
        case .ultraLight: 100
        case .thin: 200
        case .light: 300
        case .regular: 400
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }
}
