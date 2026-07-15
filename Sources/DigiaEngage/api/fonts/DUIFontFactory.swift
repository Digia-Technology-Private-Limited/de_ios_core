import SwiftUI
import UIKit

/// Protocol that controls font resolution for all Digia Engage text rendering.
///
/// Implement this protocol to supply custom fonts from your app's bundle.
/// Digia Engage uses this factory whenever it needs to render a font family name
/// from the design config (e.g. `"Inter"`, `"Roboto"`).
///
/// **Usage:**
/// ```swift
/// struct MyFontFactory: DUIFontFactory {
///     func getDefaultFont(size: Double, weight: Font.Weight, italic: Bool) -> Font {
///         Font.custom("MyFont-Regular", size: size)
///     }
///     func getFont(_ fontFamily: String, size: Double, weight: Font.Weight, italic: Bool) -> Font {
///         Font.custom("MyFont-\(weight.name)", size: size)
///     }
/// }
/// ```
public protocol DUIFontFactory {
    /// Returns the default font used when no font family is specified.
    func getDefaultFont(size: Double, weight: Font.Weight, italic: Bool) -> Font

    /// Returns a SwiftUI font for the given family, size, weight and style.
    func getFont(_ fontFamily: String, size: Double, weight: Font.Weight, italic: Bool) -> Font

    /// Returns a UIKit font for the given size, weight and style.
    ///
    /// UIKit-backed renderers (including rich nudge title and subtitle text) call
    /// this requirement through the font-factory existential. The default
    /// implementation below keeps existing custom factories source-compatible.
    func getDefaultUIFont(size: Double, weight: Font.Weight, italic: Bool) -> UIFont

    /// Returns a UIKit font for the requested family, size, weight and style.
    func getUIFont(_ fontFamily: String, size: Double, weight: Font.Weight, italic: Bool) -> UIFont
}

public extension DUIFontFactory {
    /// Returns a UIKit font for the given size, weight and style.
    /// Override to supply a custom UIFont (e.g. a bundled font registered with the system).
    func getDefaultUIFont(size: Double, weight: Font.Weight, italic: Bool) -> UIFont {
        let uiWeight = UIFont.Weight(fontWeight: DigiaFontWeight.normalized(weight))
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        guard italic else { return base }
        if let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return UIFont.italicSystemFont(ofSize: size)
    }

    /// Returns a UIKit font for the given family, size, weight and style.
    /// Override to supply a custom UIFont from your app bundle.
    func getUIFont(_ fontFamily: String, size: Double, weight: Font.Weight, italic: Bool) -> UIFont {
        getDefaultUIFont(size: size, weight: weight, italic: italic)
    }
}

private extension UIFont.Weight {
    init(fontWeight: Font.Weight) {
        switch fontWeight {
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

/// Default font factory that uses the system font.
/// Provided as a convenience when no custom font is needed.
public struct DefaultFontFactory: DUIFontFactory {
    public init() {}

    public func getDefaultFont(size: Double, weight: Font.Weight, italic: Bool) -> Font {
        var font = Font.system(size: size, weight: DigiaFontWeight.normalized(weight))
        if italic { font = font.italic() }
        return font
    }

    public func getFont(_ fontFamily: String, size: Double, weight: Font.Weight, italic: Bool) -> Font {
        getDefaultFont(size: size, weight: weight, italic: italic)
    }
}

/// Font factory backed by a single global font family name supplied via
/// `DigiaConfig.fontFamily`. Applies that family to all Digia-rendered text,
/// regardless of the family requested by the design config.
struct ConfiguredFontFactory: DUIFontFactory {
    let fontFamily: String
    private let resolvedAliases: [Int: String]

    init(fontFamily: String, fontFamilyAliases: [Int: String] = [:]) {
        self.fontFamily = fontFamily
        resolvedAliases = fontFamilyAliases
            .filter { DigiaFontWeight.supportedValues.contains($0.key) }
            .compactMapValues(Self.registeredFontName)
    }

    func getDefaultFont(size: Double, weight: Font.Weight, italic: Bool) -> Font {
        let normalizedWeight = DigiaFontWeight.normalized(weight)
        let resolvedAlias = alias(for: normalizedWeight)
        var font = if let resolvedAlias {
            Font.custom(resolvedAlias, size: size)
        } else {
            Font.custom(fontFamily, size: size).weight(normalizedWeight)
        }
        if italic { font = font.italic() }
        return font
    }

    func getFont(_ fontFamily: String, size: Double, weight: Font.Weight, italic: Bool) -> Font {
        getDefaultFont(size: size, weight: weight, italic: italic)
    }

    func getDefaultUIFont(size: Double, weight: Font.Weight, italic: Bool) -> UIFont {
        let normalizedWeight = DigiaFontWeight.normalized(weight)
        let uiWeight = UIFont.Weight(fontWeight: normalizedWeight)
        let base: UIFont
        if let resolvedAlias = alias(for: normalizedWeight),
            let exactFace = UIFont(name: resolvedAlias, size: size)
        {
            base = exactFace
        } else if !UIFont.fontNames(forFamilyName: fontFamily).isEmpty {
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: fontFamily,
                .traits: [UIFontDescriptor.TraitKey.weight: uiWeight],
            ])
            base = UIFont(descriptor: descriptor, size: size)
        } else if let exactFace = UIFont(name: fontFamily, size: size) {
            base = exactFace
        } else {
            base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        }
        guard italic, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    func getUIFont(_ fontFamily: String, size: Double, weight: Font.Weight, italic: Bool) -> UIFont {
        getDefaultUIFont(size: size, weight: weight, italic: italic)
    }

    private func alias(for weight: Font.Weight) -> String? {
        guard !resolvedAliases.isEmpty else { return nil }
        let requested = DigiaFontWeight.normalized(weight).numericValue
        let selected = DigiaFontWeight.nearestValue(to: requested, among: resolvedAliases.keys)
        return selected.flatMap { resolvedAliases[$0] }
    }

    private static func registeredFontName(_ name: String) -> String? {
        if let registeredName = UIFont.fontNames(forFamilyName: name).first {
            return registeredName
        }
        return UIFont(name: name, size: 12) == nil ? nil : name
    }
}
