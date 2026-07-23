import CoreGraphics
@testable import DigiaEngage
import Testing

@Suite("Inline carousel sizing")
struct InlineCarouselSizingTests {
    @Test("Legacy payload keeps fixed height and defaults fit to cover")
    func legacyDefaults() throws {
        let config = try #require(InlineCarouselConfig.fromJson([
        "slotKey": "home",
        "items": [["imageUrl": "https://example.com/card.png"]],
        ]))

        #expect(config.height == 180)
        #expect(config.aspectRatio == 0)
        #expect(config.items.first?.fit == .cover)
    }

    @Test("Responsive payload parses aspect ratio and supported fits")
    func responsiveSizingAndFits() throws {
        let config = try #require(InlineCarouselConfig.fromJson([
            "slotKey": "home",
            "height": 240,
            "aspectRatio": 16.0 / 9.0,
            "items": [
                ["imageUrl": "https://example.com/cover.png", "fit": "cover"],
                ["imageUrl": "https://example.com/contain.png", "fit": "contain"],
                ["imageUrl": "https://example.com/fill.png", "fit": "fill"],
            ],
        ]))

        #expect(config.height == 240)
        #expect(config.aspectRatio == 16.0 / 9.0)
        #expect(config.items.map(\.fit) == [.cover, .contain, .fill])
    }

    @Test("Invalid sizing and fit use backwards-compatible defaults")
    func invalidValues() throws {
        let config = try #require(InlineCarouselConfig.fromJson([
            "slotKey": "home",
            "height": -1,
            "aspectRatio": -Double.infinity,
            "items": [[
                "imageUrl": "https://example.com/card.png",
                "fit": "scaleDown",
            ]],
        ]))

        #expect(config.height == 180)
        #expect(config.aspectRatio == 0)
        #expect(config.items.first?.fit == .cover)
    }

    @Test("Responsive height uses visible item width after spacing")
    func responsiveGeometry() {
        let geometry = resolveInlineCarouselImageGeometry(
            availableWidth: 800,
            viewportFraction: 0.88,
            itemSpacing: 20,
            aspectRatio: 2,
            fixedHeight: 180
        )

        #expect(geometry.itemWidth == 684)
        #expect(geometry.height == 342)
    }

    @Test("Fixed height geometry retains the legacy item width")
    func legacyGeometry() {
        let geometry = resolveInlineCarouselImageGeometry(
            availableWidth: 800,
            viewportFraction: 0.88,
            itemSpacing: 20,
            aspectRatio: 0,
            fixedHeight: 180
        )

        #expect(geometry.itemWidth == 704)
        #expect(geometry.height == 180)
    }
}
