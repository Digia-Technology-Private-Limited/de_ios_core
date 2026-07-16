import SwiftUI
import UIKit
@testable import DigiaEngage
import Testing

@Suite("DigiaFont")
struct DigiaFontTests {
    @Test("an exact registered face can be configured by name")
    func configuredExactFace() {
        let fontProvider = DigiaFont(fontFamily: "Chalkduster")

        let font = fontProvider.uiKit(size: 18, weight: .bold, italic: false)

        #expect(font.fontName == "Chalkduster")
    }

    @Test("a registered family selects the requested weight")
    func configuredFamilyPreservesRequestedWeight() {
        let fontProvider = DigiaFont(fontFamily: "Avenir Next")

        let regular = fontProvider.uiKit(size: 18, weight: .regular, italic: false)
        let bold = fontProvider.uiKit(size: 18, weight: .bold, italic: false)

        #expect(regular.fontName == "AvenirNext-Regular")
        #expect(bold.fontName == "AvenirNext-Bold")
    }

    @Test("dashboard weights support the full numeric range")
    func dashboardWeightsSupportFullRange() {
        #expect(DigiaFontWeight.parse("100") == .ultraLight)
        #expect(DigiaFontWeight.parse("300") == .light)
        #expect(DigiaFontWeight.parse("800") == .heavy)
        #expect(DigiaFontWeight.parse("900") == .black)
        #expect(DigiaFontWeight.value("350") == 350)
        #expect(DigiaFontWeight.optional("extra_bold") == .heavy)
        #expect(DigiaFontWeight.parse("invalid") == .regular)
    }

    @Test("an unknown family falls back to a system font with the requested weight")
    func unknownFamilyFallsBackToWeightedSystemFont() {
        let fontProvider = DigiaFont(
            fontFamily: "DefinitelyNotARegisteredFont"
        )

        let font = fontProvider.uiKit(size: 18, weight: .bold, italic: false)

        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }
}
