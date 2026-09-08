import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

struct NudgeSurfaceConfigTests {
    @Test("parses nudge barrier color alpha as alpha-first hex")
    func parsesBarrierColorAlphaFirstHex() throws {
        let surface = NudgeSurface.fromJson(["barrierColor": "#4D000000"])
        let color = try #require(surface.barrierColor)
        let resolved = UIColor(color)
        var alpha: CGFloat = 0

        #expect(resolved.getRed(nil, green: nil, blue: nil, alpha: &alpha))
        #expect(abs(alpha - 77.0 / 255.0) < 0.001)
    }
}
