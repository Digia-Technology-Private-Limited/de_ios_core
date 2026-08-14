import UIKit

/// Creates all Digia Engage fonts from the host-configured family.
struct DigiaFont {
    private let family: String?

    init(fontFamily: String? = nil) {
        let trimmed = fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines)
        family = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Resolves the one canonical UIKit font used by both UIKit and SwiftUI renderers.
    func resolve(size: Double, weight: Int, italic: Bool, fallbackFamily: String? = nil) -> UIFont {
        let uiWeight = UIFont.Weight(campaignWeight: weight)
        let base: UIFont
        if let family {
            if !UIFont.fontNames(forFamilyName: family).isEmpty {
                let descriptor = UIFontDescriptor(fontAttributes: [
                    .family: family,
                    .traits: [UIFontDescriptor.TraitKey.weight: uiWeight],
                ])
                base = UIFont(descriptor: descriptor, size: size)
            } else if let exactFace = UIFont(name: family, size: size) {
                base = exactFace
            } else {
                base = UIFont.systemFont(ofSize: size, weight: uiWeight)
            }
        } else if let fallback = fallbackFamily?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fallback.isEmpty, !UIFont.fontNames(forFamilyName: fallback).isEmpty {
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: fallback,
                .traits: [UIFontDescriptor.TraitKey.weight: uiWeight],
            ])
            base = UIFont(descriptor: descriptor, size: size)
        } else if let fallback = fallbackFamily, let exactFace = UIFont(name: fallback, size: size) {
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

extension UIFont.Weight {
    init(campaignWeight: Int) {
        let nearestHundred = ((campaignWeight.clamped(to: 100...900) + 50) / 100) * 100
        switch nearestHundred {
        case 100: self = .ultraLight
        case 200: self = .thin
        case 300: self = .light
        case 400: self = .regular
        case 500: self = .medium
        case 600: self = .semibold
        case 700: self = .bold
        case 800: self = .heavy
        default: self = .black
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
