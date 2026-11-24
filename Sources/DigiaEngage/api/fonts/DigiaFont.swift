import CoreText
import SwiftUI
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
                base = UIFont(descriptor: weightedDescriptor(family: family, size: size, weight: weight, uiWeight: uiWeight), size: size)
            } else if let exactFace = UIFont(name: family, size: size) {
                base = exactFace
            } else {
                base = UIFont.systemFont(ofSize: size, weight: uiWeight)
            }
        } else if let fallback = fallbackFamily?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fallback.isEmpty, !UIFont.fontNames(forFamilyName: fallback).isEmpty {
            base = UIFont(descriptor: weightedDescriptor(family: fallback, size: size, weight: weight, uiWeight: uiWeight), size: size)
        } else if let fallback = fallbackFamily, let exactFace = UIFont(name: fallback, size: size) {
            base = exactFace
        } else {
            base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        }
        guard italic else { return base }
        if let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) {
            let resolved = UIFont(descriptor: descriptor, size: size)
            if resolved.fontDescriptor.symbolicTraits.contains(.traitItalic) { return resolved }
        }
        let matrix = (base.fontDescriptor.fontAttributes[.matrix] as? NSValue)?.cgAffineTransformValue ?? .identity
        let oblique = matrix.concatenating(CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0))
        let descriptor = base.fontDescriptor.addingAttributes([.matrix: NSValue(cgAffineTransform: oblique)])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// A brand font rarely covers every glyph a campaign author might type into a
    /// label (e.g. a trailing "→" appended to a CTA). When CoreText falls back to
    /// another font for such a missing glyph, the default system cascade list isn't
    /// guaranteed to match the requested weight, so a bold label can render that one
    /// glyph at regular weight. Pointing the cascade list at the system font resolved
    /// for the same weight keeps fallback-substituted glyphs visually consistent with
    /// the rest of the label.
    private func weightedDescriptor(family: String, size: Double, weight: Int, uiWeight: UIFont.Weight) -> UIFontDescriptor {
        if let face = Self.nearestFace(family: family, weight: weight) {
            return UIFontDescriptor(fontAttributes: [
                .name: face,
                .cascadeList: [cascadeDescriptor(size: size, uiWeight: uiWeight)],
            ])
        }
        return UIFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [UIFontDescriptor.TraitKey.weight: uiWeight],
            .cascadeList: [cascadeDescriptor(size: size, uiWeight: uiWeight)],
        ])
    }

    private func cascadeDescriptor(size: Double, uiWeight: UIFont.Weight) -> UIFontDescriptor {
        let systemFallback = UIFont.systemFont(ofSize: size, weight: uiWeight)
        return UIFontDescriptor(fontAttributes: [
            .family: systemFallback.familyName,
            .traits: [UIFontDescriptor.TraitKey.weight: uiWeight],
        ])
    }

    /// PostScript name of the upright face in `family` whose OS/2 `usWeightClass` is
    /// nearest `weight` by CSS font-matching. UIFont.Weight and CoreText weight traits
    /// are on different scales, so matching on traits picks the wrong face (600 -> Bold).
    private static func nearestFace(family: String, weight: Int) -> String? {
        let faces = uprightFaces(family: family)
        guard let target = nearestWeight(to: weight, in: faces.map(\.weight)) else { return nil }
        return faces.first { $0.weight == target }?.name
    }

    /// Guards ``faceCache``: fonts resolve on the main actor and on TextKit layout threads.
    private static let faceCacheLock = NSLock()
    nonisolated(unsafe) private static var faceCache: [String: [(name: String, weight: Int)]] = [:]

    /// Upright faces of `family` with their `usWeightClass`, read once per family.
    private static func uprightFaces(family: String) -> [(name: String, weight: Int)] {
        faceCacheLock.lock()
        defer { faceCacheLock.unlock() }
        if let cached = faceCache[family] { return cached }
        var faces: [(name: String, weight: Int)] = []
        for name in UIFont.fontNames(forFamilyName: family) {
            let font = UIFont(name: name, size: 12) ?? UIFont.systemFont(ofSize: 12)
            guard font.fontName == name,
                  !font.fontDescriptor.symbolicTraits.contains(.traitItalic),
                  let weightClass = usWeightClass(of: font) else { continue }
            faces.append((name, weightClass))
        }
        faceCache[family] = faces
        return faces
    }

    /// OS/2 table `usWeightClass` (big-endian UInt16 at byte offset 4), or nil if absent.
    private static func usWeightClass(of font: UIFont) -> Int? {
        guard let data = CTFontCopyTable(font as CTFont, CTFontTableTag(kCTFontTableOS2), []),
              CFDataGetLength(data) >= 6,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let value = Int(bytes[4]) << 8 | Int(bytes[5])
        return value > 0 ? value : nil
    }

    /// CSS font-matching: the available weight to use for `requested`.
    static func nearestWeight(to requested: Int, in available: [Int]) -> Int? {
        let sorted = Set(available).sorted()
        if sorted.contains(requested) { return requested }
        let lighter = sorted.filter { $0 < requested }.reversed() as [Int]
        let heavier = sorted.filter { $0 > requested }
        let order: [Int]
        if requested < 400 {
            order = lighter + heavier
        } else if requested > 500 {
            order = heavier + lighter
        } else {
            // 400...500: up to 500 first, then lighter, then heavier beyond 500.
            let within = heavier.filter { $0 <= 500 }
            order = within + lighter + heavier.filter { $0 > 500 }
        }
        return order.first
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

/// SwiftUI text font resolved through the SDK font factory. Use this for every
/// `Text`; never `Font.system` / dynamic-type styles.
@MainActor
func digiaFont(size: CGFloat, weight: Int = 400) -> Font {
    Font(SDKInstance.shared.font.resolve(size: Double(size), weight: weight, italic: false))
}
