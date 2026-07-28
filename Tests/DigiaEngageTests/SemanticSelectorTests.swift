import CoreGraphics
import XCTest
@testable import DigiaEngage

final class SemanticSelectorTests: XCTestCase {
    func testStableIdentifierMatchesUniquely() {
        let result = evaluate(
            [node("a", testId: "product-add"), node("b", testId: "cart")],
            SemanticPredicate(testId: "product-add")
        )
        XCTAssertEqual(result.status, .matched)
        XCTAssertEqual(result.node?.nodeId, "a")
    }

    func testAccessibilityLabelAndTextNormalizeWhitespaceAndCase() {
        let result = evaluate(
            [node("a", text: "  Add\n to CART ", description: " Buy now ")],
            SemanticPredicate(text: "add to cart", contentDescription: "buy NOW")
        )
        XCTAssertEqual(result.status, .matched)
    }

    func testAncestorDisambiguatesDuplicateButtons() {
        let nodes = [
            node("card-a", actionable: false, descendantText: ["Whey Protein"]),
            node("add-a", parent: "card-a", text: "Add"),
            node("card-b", actionable: false, descendantText: ["Casein"]),
            node("add-b", parent: "card-b", text: "Add"),
        ]
        let result = SemanticSelectorEvaluator.evaluate(
            nodes: nodes,
            selector: SemanticSelectorV1(
                node: SemanticPredicate(text: "Add"),
                ancestors: [SemanticPredicate(descendantText: "Casein")],
                indexAmongMatches: nil
            )
        )
        XCTAssertEqual(result.node?.nodeId, "add-b")
    }

    func testIndexFallbackSelectsRequestedDuplicate() {
        let result = SemanticSelectorEvaluator.evaluate(
            nodes: [node("a", text: "Add"), node("b", text: "Add")],
            selector: SemanticSelectorV1(
                node: SemanticPredicate(text: "Add"),
                ancestors: [],
                indexAmongMatches: 1
            )
        )
        XCTAssertEqual(result.node?.nodeId, "b")
        XCTAssertEqual(result.matchCount, 2)
    }

    func testDuplicateWithoutFallbackIsAmbiguous() {
        let result = evaluate(
            [node("a", text: "Add"), node("b", text: "Add")],
            SemanticPredicate(text: "Add")
        )
        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertEqual(result.matchCount, 2)
    }

    func testMissingInvisibleAndDisabledNodesDoNotMatch() {
        XCTAssertEqual(evaluate([], SemanticPredicate(text: "Add")).status, .notFound)
        XCTAssertEqual(
            evaluate([node("a", text: "Add", visible: false)], SemanticPredicate(text: "Add")).status,
            .notFound
        )
        XCTAssertEqual(
            evaluate([node("a", text: "Add", enabled: false)], SemanticPredicate(text: "Add")).status,
            .notFound
        )
    }

    func testSemanticTargetRejectsCoordinatesAndUnknownVersion() {
        XCTAssertNil(SemanticTarget.fromJson([
            "type": "semantic",
            "pageKey": "home",
            "x": 10,
            "selector": ["version": 1, "node": ["text": "Add"]],
        ]))
        XCTAssertNil(SemanticTarget.fromJson([
            "type": "semantic",
            "pageKey": "home",
            "selector": ["version": 2, "node": ["text": "Add"]],
        ]))
    }

    func testSpotlightCampaignParsesSemanticTargetAndRnGlow() {
        let campaign = CampaignModel.fromJson([
            "id": "campaign",
            "campaignKey": "home_brands",
            "campaignType": "guide",
            "templateConfig": [
                "templateType": "spotlight",
                "steps": [[
                    "target": [
                        "type": "semantic",
                        "pageKey": "home",
                        "selector": [
                            "version": 1,
                            "node": [
                                "role": "button",
                                "contentDescription": "Brands",
                            ],
                        ],
                    ],
                    "title": "Explore brands",
                    "overlayColor": "#010203",
                    "overlayOpacity": 0.55,
                    "highlightGlowColor": "#22C55E",
                    "highlightGlowWidth": 4,
                ]],
            ],
        ])

        let step = campaign?.guideConfig?.steps.first
        XCTAssertEqual(step?.semanticTarget?.pageKey, "home")
        XCTAssertEqual(step?.widgetConfig.overlay.cutout.glowColor, "#22C55E")
        XCTAssertEqual(step?.widgetConfig.overlay.cutout.glowWidth, 4)
        XCTAssertTrue(step?.widgetConfig.overlay.visible == true)
    }

    private func evaluate(
        _ nodes: [SemanticNodeSnapshot],
        _ predicate: SemanticPredicate
    ) -> SemanticMatchResult {
        SemanticSelectorEvaluator.evaluate(
            nodes: nodes,
            selector: SemanticSelectorV1(node: predicate, ancestors: [], indexAmongMatches: nil)
        )
    }

    private func node(
        _ id: String,
        parent: String? = nil,
        testId: String? = nil,
        text: String? = nil,
        description: String? = nil,
        actionable: Bool = true,
        enabled: Bool = true,
        visible: Bool = true,
        descendantText: [String] = []
    ) -> SemanticNodeSnapshot {
        SemanticNodeSnapshot(
            nodeId: id,
            parentId: parent,
            className: "RCTView",
            role: "button",
            resourceId: nil,
            testId: testId,
            text: text,
            contentDescription: description,
            descendantText: descendantText,
            indexInParent: 0,
            actionable: actionable,
            enabled: enabled,
            visible: visible,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 40)
        )
    }
}
