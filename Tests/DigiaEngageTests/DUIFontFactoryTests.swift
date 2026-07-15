import SwiftUI
import UIKit
@testable import DigiaEngage
import Testing

@Suite("DUIFontFactory")
struct DUIFontFactoryTests {
    @Test("configured UIKit font dispatches through the protocol")
    func configuredUIKitFontDispatchesThroughProtocol() {
        let factory: any DUIFontFactory = ConfiguredFontFactory(fontFamily: "Chalkduster")

        let font = factory.getDefaultUIFont(size: 18, weight: .bold, italic: false)

        #expect(font.fontName == "Chalkduster")
    }

    @Test("configured aliases select the exact requested UIKit face")
    func configuredAliasesSelectExactFace() {
        let factory: any DUIFontFactory = ConfiguredFontFactory(
            fontFamily: "Avenir Next",
            fontFamilyAliases: [
                400: "AvenirNext-Regular",
                500: "AvenirNext-Medium",
                600: "AvenirNext-DemiBold",
                700: "AvenirNext-Bold",
            ]
        )

        #expect(factory.getDefaultUIFont(size: 18, weight: .regular, italic: false).fontName == "AvenirNext-Regular")
        #expect(factory.getDefaultUIFont(size: 18, weight: .medium, italic: false).fontName == "AvenirNext-Medium")
        #expect(factory.getDefaultUIFont(size: 18, weight: .semibold, italic: false).fontName == "AvenirNext-DemiBold")
        #expect(factory.getDefaultUIFont(size: 18, weight: .bold, italic: false).fontName == "AvenirNext-Bold")
    }

    @Test("missing weights use the nearest configured face and prefer the heavier tie")
    func configuredAliasesUseNearestFace() {
        let factory: any DUIFontFactory = ConfiguredFontFactory(
            fontFamily: "Avenir Next",
            fontFamilyAliases: [
                400: "AvenirNext-Regular",
                600: "AvenirNext-DemiBold",
                700: "AvenirNext-Bold",
            ]
        )

        #expect(factory.getDefaultUIFont(size: 18, weight: .medium, italic: false).fontName == "AvenirNext-DemiBold")
        #expect(factory.getDefaultUIFont(size: 18, weight: .black, italic: false).fontName == "AvenirNext-Bold")
    }

    @Test("a registered family without aliases still selects the requested weight")
    func configuredFamilyPreservesRequestedWeight() {
        let factory: any DUIFontFactory = ConfiguredFontFactory(fontFamily: "Avenir Next")

        let regular = factory.getDefaultUIFont(size: 18, weight: .regular, italic: false)
        let bold = factory.getDefaultUIFont(size: 18, weight: .bold, italic: false)

        #expect(regular.fontName == "AvenirNext-Regular")
        #expect(bold.fontName == "AvenirNext-Bold")
    }

    @Test("unexpected weights normalize to the nearest supported weight")
    func unexpectedWeightsNormalizeToSupportedWeight() {
        #expect(DigiaFontWeight.normalized(.light) == .regular)
        #expect(DigiaFontWeight.normalized(.heavy) == .bold)
        #expect(DigiaFontWeight.normalized(450) == 500)
    }

    @Test("an unknown family falls back to a system font with the requested weight")
    func unknownFamilyFallsBackToWeightedSystemFont() {
        let factory: any DUIFontFactory = ConfiguredFontFactory(
            fontFamily: "DefinitelyNotARegisteredFont"
        )

        let font = factory.getDefaultUIFont(size: 18, weight: .bold, italic: false)

        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }
}
