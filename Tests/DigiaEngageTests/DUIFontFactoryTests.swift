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
}
