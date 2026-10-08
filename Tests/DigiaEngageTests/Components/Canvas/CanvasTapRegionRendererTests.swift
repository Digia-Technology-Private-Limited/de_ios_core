import Foundation
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas tap region renderer", .serialized, .tags(.canvas, .component))
struct CanvasTapRegionRendererTests {

    // MARK: - 1. TapRegion Subsystem: Parser & Geometry

    @Test("tapRegion parser scales normalized rect to canvas bounds and preserves actions and primary flag")
    func tapRegionParserPreservesGeometry() throws {
        let canvas = try parsedCanvas(children: [
            [
                "kind": "tapRegion",
                "id": "hero-cta",
                "rect": ["x": 0.1, "y": 0.2, "width": 0.5, "height": 0.4],
                "isPrimary": true,
                "onClick": [
                    "steps": [
                        [
                            "type": "open_url",
                            "data": ["url": "https://example.com/special"]
                        ]
                    ]
                ]
            ]
        ])
        #expect(canvas.children.count == 1)
        guard case .tapRegion(let id, let rect, let actions, let isPrimary) = canvas.children.first else {
            Issue.record("Expected tapRegion child")
            return
        }
        #expect(id == "hero-cta")
        // Normalized (0.1, 0.2, 0.5, 0.4) on canvas (300, 200)
        #expect(rect == CampaignCanvasRect(x: 30, y: 40, width: 150, height: 80))
        #expect(isPrimary == true)
        #expect(actions.count == 1)
        if case .openUrl(let url) = actions.first {
            #expect(url == "https://example.com/special")
        } else {
            Issue.record("Expected openUrl action")
        }
    }

    @Test("tapRegion parser filters empty non-primary regions but retains primary or actionable regions")
    func tapRegionFilteringOracle() throws {
        let canvas = try parsedCanvas(children: [
            // 1. Non-primary with NO actions -> MUST be dropped
            [
                "kind": "tapRegion",
                "id": "empty-passive",
                "rect": ["x": 0.0, "y": 0.0, "width": 0.2, "height": 0.2],
                "isPrimary": false
            ],
            // 2. Primary with NO actions -> MUST be retained
            [
                "kind": "tapRegion",
                "id": "primary-tap",
                "rect": ["x": 0.2, "y": 0.0, "width": 0.2, "height": 0.2],
                "isPrimary": true
            ],
            // 3. Non-primary with actions -> MUST be retained
            [
                "kind": "tapRegion",
                "id": "actionable-tap",
                "rect": ["x": 0.4, "y": 0.0, "width": 0.2, "height": 0.2],
                "isPrimary": false,
                "onClick": [
                    "steps": [["type": "Action.hideInline"]]
                ]
            ]
        ])
        #expect(canvas.children.count == 2)
        #expect(canvas.children.map(\.id) == ["primary-tap", "actionable-tap"])
    }

    // MARK: - 2. TapRegion Subsystem: Properties & Hit Testing

    @Test("tapRegion child properties correctly expose isHitTestable and clipsToAuthoredRect")
    func tapRegionChildProperties() {
        let activeChild = CampaignCanvasChild.tapRegion(
            id: "tap1",
            rect: CampaignCanvasRect(x: 10, y: 10, width: 100, height: 50),
            actions: [EngageAction.openUrl("https://example.com")],
            isPrimary: false
        )
        #expect(activeChild.id == "tap1")
        #expect(activeChild.rect == CampaignCanvasRect(x: 10, y: 10, width: 100, height: 50))
        #expect(activeChild.isHitTestable == true)
        #expect(activeChild.clipsToAuthoredRect == true)

        let primaryEmptyChild = CampaignCanvasChild.tapRegion(
            id: "tap2",
            rect: CampaignCanvasRect(x: 0, y: 0, width: 200, height: 100),
            actions: [],
            isPrimary: true
        )
        #expect(primaryEmptyChild.isHitTestable == true)

        let passiveEmptyChild = CampaignCanvasChild.tapRegion(
            id: "tap3",
            rect: CampaignCanvasRect(x: 0, y: 0, width: 200, height: 100),
            actions: [],
            isPrimary: false
        )
        // All tapRegions in the model layer are hitTestable; pruning occurs during parser phase
        #expect(passiveEmptyChild.isHitTestable == true)
    }

    // MARK: - 3. TapRegion Subsystem: Action Request & Mount

    @Test(
        "canvasTapRegionActionRequest routes tap regions with correct elementId and flags",
        arguments: [true, false]
    )
    func tapRegionActionRequestRouting(isPrimary: Bool) {
        let actions = [EngageAction.openUrl("https://example.com")]
        let request = canvasTapRegionActionRequest(
            actions: actions,
            elementId: "region-1",
            isPrimary: isPrimary
        )
        #expect(request.isPrimary == isPrimary)
        #expect(request.elementId == "region-1")
        #expect(request.actions == actions)
    }


    // MARK: - Test Helpers

    private func parsedCanvas(children: [[String: Any]]) throws -> CampaignCanvas {
        try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 300,
            "canvasHeight": 200,
            "children": children
        ])
    }
}
