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

    private func baseStory() -> [String: Any] {
        [
            "slotKey": "home_stories",
            "items": [["type": "image", "url": "https://example.com/story.jpg"]],
        ]
    }
}
