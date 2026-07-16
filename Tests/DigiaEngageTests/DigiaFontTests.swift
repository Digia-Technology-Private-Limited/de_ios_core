import UIKit
@testable import DigiaEngage
import Testing

@Suite("DigiaFont")
struct DigiaFontTests {
    @Test("an exact registered face can be configured by name")
    func configuredExactFace() {
        let fontProvider = DigiaFont(fontFamily: "Chalkduster")

        let font = fontProvider.resolve(size: 18, weight: 700, italic: false)

        #expect(font.fontName == "Chalkduster")
    }

    @Test("a registered family selects the requested weight")
    func configuredFamilyPreservesRequestedWeight() {
        let fontProvider = DigiaFont(fontFamily: "Avenir Next")

        let regular = fontProvider.resolve(size: 18, weight: 400, italic: false)
        let bold = fontProvider.resolve(size: 18, weight: 700, italic: false)

        #expect(regular.fontName == "AvenirNext-Regular")
        #expect(bold.fontName == "AvenirNext-Bold")
    }

    @Test("dashboard weights support the full numeric range")
    func dashboardWeightsSupportFullRange() {
        #expect(DigiaFontWeight.value("100") == 100)
        #expect(DigiaFontWeight.value("300") == 300)
        #expect(DigiaFontWeight.value("800") == 800)
        #expect(DigiaFontWeight.value("900") == 900)
        #expect(DigiaFontWeight.value("350") == 350)
        #expect(DigiaFontWeight.optional("extra_bold") == 800)
        #expect(DigiaFontWeight.value("invalid") == 400)
    }

    @Test("UIKit maps numeric campaign weights once at the platform boundary")
    func numericWeightsMapAtPlatformBoundary() {
        #expect(UIFont.Weight(campaignWeight: 100) == .ultraLight)
        #expect(UIFont.Weight(campaignWeight: 400) == .regular)
        #expect(UIFont.Weight(campaignWeight: 450) == .medium)
        #expect(UIFont.Weight(campaignWeight: 700) == .bold)
        #expect(UIFont.Weight(campaignWeight: 900) == .black)
    }

    @Test("an unknown family falls back to a system font with the requested weight")
    func unknownFamilyFallsBackToWeightedSystemFont() {
        let fontProvider = DigiaFont(
            fontFamily: "DefinitelyNotARegisteredFont"
        )

        let font = fontProvider.resolve(size: 18, weight: 700, italic: false)

        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }
}
