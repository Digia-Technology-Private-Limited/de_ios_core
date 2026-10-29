import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// Which action a tap on a Canvas text block fires (TXT-I01–I05).
/// `canvas_tap_targets/canvas_text_span_taps` sizes every text element to exactly its lines (left/top,
/// fixed sizing, 30 pt line height, no padding), so a tap `y` points below the element's top lands on
/// line `floor(y / 30)`. Every tap is a real touch on the card the SDK rendered in the app's
/// `DigiaSlot`; the proof is the exact list of URLs the host's open-URL handler is asked to open, so a
/// doubled or missing fire fails.
@Suite("Canvas: text span taps", .serialized,
       .tags(.integration, .behaviour, .canvas))
@MainActor
struct CanvasTextSpanTapTests {

    /// Shows the card, taps the element authored with [id] at [x], [y] points from its top-left, and
    /// returns every URL the host was asked to open.
    private func tap(_ id: String, x: CGFloat, y: CGFloat, expectsOpen: Bool = true) async throws -> [String] {
        let campaign = try fixture("canvas_tap_targets/canvas_text_span_taps")
        let sdk = try await SdkHarness.start(campaign)
        defer { sdk.tearDown() }
        let opened = Received<String>()
        sdk.setOpenURLHandler { opened.append($0) }
        try sdk.mount { DigiaSlot("home_banner") { EmptyView() } }
        try sdk.deliver(keyOf(campaign))

        try await sdk.tap(id: id, at: CGPoint(x: x, y: y))

        if expectsOpen {
            try await sdk.waitUntil("a URL is opened") { !opened.values.isEmpty }
            try await sdk.settle(0.3) // a second, doubled open would land by now
        } else {
            try await sdk.settle(0.5) // long past when a wrongly fired open would have landed
        }
        #expect(sdk.platform.opened.isEmpty, "the host's handler took it, not iOS")
        return opened.values
    }

    // TXT-I01
    // Fails if: CampaignCanvasView.swift `attributedString` stops tagging an actionable span with
    // `.link` (`digia-canvas://span/<index>`), so the text view has no link to hit.
    @Test("a tap on the first line fires only the first span's action")
    func firstSpan() async throws {
        #expect(try await tap("span_lines", x: 12, y: 15) == ["https://digia.com/hit/span-one"])
    }

    // TXT-I01
    // Fails if: CanvasRichText.Coordinator `shouldInteractWith` maps the link to a span other than
    // `spans[index]` (the index is the span's position in the block).
    @Test("a tap on the second line fires only the second span's action")
    func middleSpan() async throws {
        #expect(try await tap("span_lines", x: 12, y: 45) == ["https://digia.com/hit/span-two"])
    }

    // TXT-I01
    // Fails if: CanvasRichText.Coordinator `shouldInteractWith` maps the link to a span other than
    // `spans[index]`.
    @Test("a tap on the last line fires only the last span's action")
    func lastSpan() async throws {
        #expect(try await tap("span_lines", x: 12, y: 105) == ["https://digia.com/hit/span-three"])
    }

    // TXT-I03
    // No single SDK line decides this: it guards against UIKit's link hit slop letting a tap on a
    // link-less line reach the links on the lines above and below it.
    @Test("a tap on a span without an action fires nothing")
    func plainSpan() async throws {
        #expect(try await tap("span_lines", x: 12, y: 75, expectsOpen: false) == [])
    }

    // TXT-I02
    // Fails if: CampaignCanvasView.swift `attributedString` stops tagging an actionable span with `.link`.
    @Test("a wrapping span fires its action from its first line")
    func wrappedSpanFirstLine() async throws {
        #expect(try await tap("span_wrapped", x: 12, y: 15) == ["https://digia.com/hit/span-wrapped"])
    }

    // TXT-I02
    // Fails if: CampaignCanvasView.swift `attributedString` stops tagging an actionable span with `.link`.
    @Test("a wrapping span fires its action from its second line")
    func wrappedSpanSecondLine() async throws {
        #expect(try await tap("span_wrapped", x: 12, y: 45) == ["https://digia.com/hit/span-wrapped"])
    }

    // TXT-I04
    // Fails if: CampaignCanvasModels.swift `isHitTestable` for `.text` returns `true` regardless of
    // whether a span has actions (the plain text would swallow the touch).
    @Test("plain text over a tap region lets the region take the tap")
    func plainTextPassesTheTap() async throws {
        #expect(try await tap("plain_over_region", x: 12, y: 15) == ["https://digia.com/hit/region-under-plain"])
    }

    // TXT-I05
    // Fails if: CampaignCanvasModels.swift `isHitTestable` for `.text` returns `false` (the link would
    // let the touch through to the region under it).
    @Test("a link over a tap region fires only the link's action")
    func linkOverRegionWins() async throws {
        #expect(try await tap("link_over_region", x: 12, y: 15) == ["https://digia.com/hit/span-over-region"])
    }
}
}
