import SwiftUI
import UIKit

/// Creates all Digia Engage fonts from the host-configured family.
struct DigiaFont {
    private let family: String?

    init(fontFamily: String? = nil) {
        let trimmed = fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines)
        family = trimmed?.isEmpty == false ? trimmed : nil
    }

    func swiftUI(size: Double, weight: Font.Weight, italic: Bool) -> Font {
        Font(uiKit(size: size, weight: weight, italic: italic))
    }

    func uiKit(size: Double, weight: Font.Weight, italic: Bool) -> UIFont {
        let uiWeight = UIFont.Weight(weight)
        let base: UIFont
        if let family, !UIFont.fontNames(forFamilyName: family).isEmpty {
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [UIFontDescriptor.TraitKey.weight: uiWeight],
            ])
            base = UIFont(descriptor: descriptor, size: size)
        } else if let family, let exactFace = UIFont(name: family, size: size) {
            base = exactFace
        } else {
            base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        }
        guard italic, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}

private extension UIFont.Weight {
    init(_ weight: Font.Weight) {
        switch weight {
        case .ultraLight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        default: self = .regular
        }
    }
}
