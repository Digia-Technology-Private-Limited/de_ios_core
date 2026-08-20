import Foundation
@testable import DigiaEngage
import Testing

@MainActor
@Suite("Inline canvas", .serialized)
struct InlineCanvasTests {

    @Test("reads slot, chrome and the shared canvas block")
    func parsesCanonicalConfig() throws {
        let config = try #require(InlineCanvasConfig.fromJson(Self.templateConfig()))

        #expect(config.slotKey == "home_hero")
        #expect(config.designWidth == 360)
        #expect(config.cornerRadius == 12)
        #expect(config.margin.left == 16)
        #expect(config.margin.horizontal == 32)
        #expect(config.canvas.width == 360)
        #expect(config.canvas.height == 180)
    }

    @Test("falls back to the canvas width when designWidth is absent")
    func fallsBackToCanvasWidth() throws {
        var json = Self.templateConfig()
        json.removeValue(forKey: "designWidth")
        let config = try #require(InlineCanvasConfig.fromJson(json))
        #expect(config.designWidth == 360)
    }

    @Test("rejects a payload with no slot to render into")
    func rejectsBlankSlotKey() {
        #expect(InlineCanvasConfig.fromJson(Self.templateConfig(slotKey: "   ")) == nil)
    }

    @Test("rejects a canvas version this build cannot read")
    func rejectsUnknownCanvasVersion() {
        // Collapsing the slot beats rendering a half-understood card: the app
        // shows its own content instead.
        #expect(InlineCanvasConfig.fromJson(Self.templateConfig(canvasVersion: 3)) == nil)
    }

    @Test("hideInline parses into the shared dismiss action")
    func parsesHideInline() throws {
        let actions = EngageActionParser().parse(["steps": [["type": "Action.hideInline"]]])
        let first = try #require(actions.first)
        guard case .dismiss = first else {
            Issue.record("Action.hideInline should parse as dismiss")
            return
        }
    }

    @Test("overlay hide spellings still parse")
    func parsesOverlayHideSpellings() throws {
        for type in ["Action.hideBottomSheet", "Action.dismissDialog"] {
            let actions = EngageActionParser().parse(["steps": [["type": type]]])
            let first = try #require(actions.first, "\(type) should parse")
            guard case .dismiss = first else {
                Issue.record("\(type) should parse as dismiss")
                return
            }
        }
    }

    private static func templateConfig(
        slotKey: String = "home_hero",
        canvasVersion: Int = 2
    ) -> [String: Any] {
        [
            "templateType": "canvas",
            "slotKey": slotKey,
            "designWidth": 360,
            "cornerRadius": 12,
            "layout": ["margin": ["top": 0, "right": 16, "bottom": 12, "left": 16]],
            "canvas": [
                "version": canvasVersion,
                "canvasWidth": 360,
                "canvasHeight": 180,
                "background": ["type": "solid", "color": ["value": "#FFFFFFFF"]],
                "children": [],
            ],
        ]
    }
}
