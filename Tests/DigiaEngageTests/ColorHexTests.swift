import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

struct ColorHexTests {
    @Test("parses campaign colors as alpha-first AARRGGBB")
    func parsesAlphaFirstHex() throws {
        let color = try #require(Color(hex: "#80112233"))
        let resolved = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        #expect(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(abs(red - 17.0 / 255.0) < 0.001)
        #expect(abs(green - 34.0 / 255.0) < 0.001)
        #expect(abs(blue - 51.0 / 255.0) < 0.001)
        #expect(abs(alpha - 128.0 / 255.0) < 0.001)
    }
}
