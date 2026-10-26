import SwiftUI
import Testing
@testable import DigiaEngage

@Suite("BlurHash placeholder fit", .tags(.contract, .inline))
struct BlurHashPlaceholderFitTests {
    @Test("placeholder content mode follows the wire fit")
    func mapsFitToContentMode() {
        #expect(BlurHashPlaceholderView(placeholder: nil, fit: "cover").contentMode == .fill)
        #expect(BlurHashPlaceholderView(placeholder: nil, fit: "contain").contentMode == .fit)
        #expect(BlurHashPlaceholderView(placeholder: nil, fit: "fill").contentMode == nil)
        // Unknown wire values fall back to the default cover rendering.
        #expect(BlurHashPlaceholderView(placeholder: nil, fit: "future-fit").contentMode == .fill)
    }

    @Test("fit enums round-trip the wire strings")
    func rawValuesMatchWireStrings() {
        #expect(NudgeContentFit.cover.rawValue == "cover")
        #expect(NudgeContentFit.contain.rawValue == "contain")
        #expect(NudgeContentFit.fill.rawValue == "fill")
        #expect(InlineBannerBoxFit.cover.rawValue == "cover")
        #expect(InlineBannerBoxFit.contain.rawValue == "contain")
        #expect(InlineBannerBoxFit.fill.rawValue == "fill")
        #expect(StoryMediaFit.cover.rawValue == "cover")
        #expect(StoryMediaFit.contain.rawValue == "contain")
        #expect(StoryMediaFit.fill.rawValue == "fill")
    }
}
