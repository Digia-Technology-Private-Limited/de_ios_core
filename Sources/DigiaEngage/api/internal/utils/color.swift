import SwiftUI

extension Color {
    init?(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        switch sanitized.count {
        case 6:
            guard let value = Int(sanitized, radix: 16) else { return nil }
            self.init(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255.0,
                green: Double((value >> 8) & 0xFF) / 255.0,
                blue: Double(value & 0xFF) / 255.0,
                opacity: 1.0
            )
        case 8:
            // Match Flutter `Color(0xAARRGGBB)` semantics used across widget configs.
            guard let value = UInt64(sanitized, radix: 16) else { return nil }
            let a = Double((value >> 24) & 0xFF) / 255.0
            let r = Double((value >> 16) & 0xFF) / 255.0
            let g = Double((value >> 8) & 0xFF) / 255.0
            let b = Double(value & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
        default:
            return nil
        }
    }
}
