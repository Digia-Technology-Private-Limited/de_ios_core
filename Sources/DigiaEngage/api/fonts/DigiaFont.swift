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
                base = UIFont(descriptor: weightedDescriptor(family: family, size: size, uiWeight: uiWeight), size: size)
            } else if let exactFace = UIFont(name: family, size: size) {
                base = exactFace
            } else {
                base = UIFont.systemFont(ofSize: size, weight: uiWeight)
            }
        } else if let fallback = fallbackFamily?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fallback.isEmpty, !UIFont.fontNames(forFamilyName: fallback).isEmpty {
            base = UIFont(descriptor: weightedDescriptor(family: fallback, size: size, uiWeight: uiWeight), size: size)
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

    /// A brand font rarely covers every glyph a campaign author might type into a
    /// label (e.g. a trailing "→" appended to a CTA). When CoreText falls back to
    /// another font for such a missing glyph, the default system cascade list isn't
    /// guaranteed to match the requested weight, so a bold label can render that one
    /// glyph at regular weight. Pointing the cascade list at the system font resolved
    /// for the same weight keeps fallback-substituted glyphs visually consistent with
    /// the rest of the label.
    private func weightedDescriptor(family: String, size: Double, uiWeight: UIFont.Weight) -> UIFontDescriptor {
        let systemFallback = UIFont.systemFont(ofSize: size, weight: uiWeight)
        let cascadeDescriptor = UIFontDescriptor(fontAttributes: [
            .family: systemFallback.familyName,
            .traits: [UIFontDescriptor.TraitKey.weight: uiWeight],
        ])
        return UIFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [UIFontDescriptor.TraitKey.weight: uiWeight],
            .cascadeList: [cascadeDescriptor],
        ])
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
