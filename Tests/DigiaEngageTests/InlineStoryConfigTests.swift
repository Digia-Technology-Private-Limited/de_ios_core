@testable import DigiaEngage
import Testing

@Suite("Inline story config")
struct InlineStoryConfigTests {
    @Test("parses close and mute overlay buttons")
    func parsesOverlayButtons() throws {
        let config = try #require(InlineStoryConfig.fromJson([
            "slotKey": "home_stories",
            "items": [["type": "video", "url": "https://example.com/story.mp4"]],
            "closeButton": [
                "visible": true,
                "iconColor": "#112233",
                "backgroundColor": "#445566",
                "size": 16,
            ],
            "muteButton": [
                "visible": true,
                "iconColor": "#AABBCC",
                "backgroundColor": "#DDEEFF",
                "size": 52,
            ],
        ]))

        #expect(config.closeButton.visible)
        #expect(config.closeButton.iconColor == "#112233")
        #expect(config.closeButton.backgroundColor == "#445566")
        #expect(config.closeButton.size == 16)
        #expect(config.muteButton.visible)
        #expect(config.muteButton.iconColor == "#AABBCC")
        #expect(config.muteButton.backgroundColor == "#DDEEFF")
        #expect(config.muteButton.size == 52)
    }

    @Test("legacy buttons stay hidden and invalid sizes use the default")
    func preservesLegacyDefaults() throws {
        let legacy = try #require(InlineStoryConfig.fromJson(baseStory()))
        var malformedJson = baseStory()
        malformedJson["closeButton"] = ["visible": true, "size": 0]
        malformedJson["muteButton"] = ["visible": true, "size": -12]
        let malformed = try #require(InlineStoryConfig.fromJson(malformedJson))

        #expect(!legacy.closeButton.visible)
        #expect(!legacy.muteButton.visible)
        #expect(malformed.closeButton.size == 36)
        #expect(malformed.muteButton.size == 36)
    }

    @Test("parses the story-level starting audio state")
    func parsesStartMuted() throws {
        var mutedJson = baseStory()
        mutedJson["startMuted"] = true

        let muted = try #require(InlineStoryConfig.fromJson(mutedJson))
        let legacy = try #require(InlineStoryConfig.fromJson(baseStory()))

        #expect(muted.startMuted)
        #expect(!legacy.startMuted)
    }

    @Test("a {value} envelope is not unwrapped: wrapped urls are dropped, wrapped flags stay default")
    func dropsValueEnvelopes() throws {
        let config = try #require(InlineStoryConfig.fromJson([
            "slotKey": "home_stories",
            "items": [
                ["type": "image", "url": ["value": "https://example.com/wrapped.jpg"]],
                ["type": "image", "url": "https://example.com/plain.jpg", "ctaEnabled": ["value": true]],
                ["type": "image", "url": "https://example.com/cta.jpg", "ctaEnabled": true],
            ],
        ]))

        #expect(config.items.count == 2)
        #expect(config.items[0].url == "https://example.com/plain.jpg")
        #expect(config.items[0].ctaEnabled == false)
        #expect(config.items[1].url == "https://example.com/cta.jpg")
        #expect(config.items[1].ctaEnabled == true)

        let onlyWrapped = InlineStoryConfig.fromJson([
            "slotKey": "home_stories",
            "items": [["type": "image", "url": ["value": "https://example.com/wrapped.jpg"]]],
        ])
        #expect(onlyWrapped == nil)
    }

    private func baseStory() -> [String: Any] {
        [
            "slotKey": "home_stories",
            "items": [["type": "image", "url": "https://example.com/story.jpg"]],
        ]
    }
}
