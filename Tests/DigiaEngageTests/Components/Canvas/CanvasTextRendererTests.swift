import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
@MainActor
@Suite("Canvas text renderer", .serialized, .tags(.canvas, .component))
struct CanvasTextRendererTests {

    // MARK: - 1. Parser & Schema Preservation

    @Test("text parser preserves block layout alignment and shadow properties")
    func parserPreservesBlockLayoutAndShadow() throws {
        let widget = try parsedText([
            "horizontalAlign": "center",
            "textAlign": "center",
            "verticalAlign": "center",
            "maxLines": 3,
            "overflow": "ellipsis",
            "sizingMode": "fixed",
            "spans": [["text": "Hello World"]],
            "shadow": [
                "color": "#00000033",
                "blur": 8,
                "spread": 2,
                "offsetX": 1,
                "offsetY": 3
            ]
        ])

        guard case .text(_, let block, let shadow) = widget else {
            Issue.record("Expected a parsed text widget")
            return
        }

        #expect(block.horizontalAlign == .center)
        #expect(block.textAlign == .center)
        #expect(block.verticalAlign == .center)
        #expect(block.maxLines == 3)
        #expect(block.overflow == "ellipsis")
        #expect(block.sizingMode == "fixed")

        #expect(shadow?.color.lightHex == "#00000033")
        #expect(shadow?.blur == 8)
        #expect(shadow?.spread == 2)
        #expect(shadow?.offsetX == 1)
        #expect(shadow?.offsetY == 3)
    }

    @Test("text parser preserves single span with full typography, decorations, and colors")
    func parserPreservesSingleSpan() throws {
        let widget = try parsedText([
            "spans": [
                [
                    "text": "Hello World",
                    "fontFamily": "Helvetica Neue",
                    "fontSize": 18,
                    "fontWeight": 700,
                    "lineHeight": 24,
                    "letterSpacing": 1.5,
                    "color": "#112233FF",
                    "highlightColor": "#FFFF0088",
                    "italic": true,
                    "decoration": "underline",
                    "decorationColor": "#FF0000FF",
                    "decorationThickness": 2,
                    "decorationOffset": 4,
                    "onClick": [
                        "steps": [
                            [
                                "type": "open_url",
                                "data": ["url": "https://example.com/tap"]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        guard case .text(_, let block, _) = widget else {
            Issue.record("Expected a parsed text widget")
            return
        }

        #expect(block.spans.count == 1)
        let span = block.spans[0]
        #expect(span.text == "Hello World")
        #expect(span.typography?.fontFamily == "Helvetica Neue")
        #expect(span.typography?.fontSize == 18)
        #expect(span.typography?.fontWeight == 700)
        #expect(span.typography?.lineHeight == 24)
        #expect(span.typography?.letterSpacing == 1.5)
        #expect(span.color?.lightHex == "#112233FF")
        #expect(span.highlightColor?.lightHex == "#FFFF0088")
        #expect(span.italic == true)
        #expect(span.decoration == .underline)
        #expect(span.decorationColor?.lightHex == "#FF0000FF")
        #expect(span.decorationThickness == 2)
        #expect(span.decorationOffset == 4)
        #expect(span.actions == [.openUrl("https://example.com/tap")])
    }

    @Test("text parser preserves multiple rich spans with mixed styling")
    func parserPreservesRichSpans() throws {
        let widget = try parsedText([
            "spans": [
                [
                    "text": "Get ",
                    "fontWeight": 400,
                    "color": "#333333FF"
                ],
                [
                    "text": "50% OFF",
                    "fontWeight": 800,
                    "color": "#FF0000FF",
                    "decoration": "lineThrough",
                    "decorationColor": "#000000FF"
                ],
                [
                    "text": " today!",
                    "fontWeight": 600,
                    "italic": true,
                    "color": "#008800FF"
                ]
            ]
        ])

        guard case .text(_, let block, _) = widget else {
            Issue.record("Expected a parsed text widget")
            return
        }

        #expect(block.spans.count == 3)
        #expect(block.spans[0].text == "Get ")
        #expect(block.spans[0].typography?.fontWeight == 400)
        #expect(block.spans[1].text == "50% OFF")
        #expect(block.spans[1].typography?.fontWeight == 800)
        #expect(block.spans[1].decoration == .lineThrough)
        #expect(block.spans[2].text == " today!")
        #expect(block.spans[2].italic == true)
    }

    // MARK: - 2. Parser Defaults & Clamping

    @Test("text parser applies robust defaults when options are omitted")
    func parserDefaults() throws {
        let widget = try parsedText([:])

        guard case .text(_, let block, let shadow) = widget else {
            Issue.record("Expected a parsed text widget")
            return
        }

        #expect(block.horizontalAlign == .left)
        #expect(block.textAlign == .left)
        #expect(block.verticalAlign == .top)
        #expect(block.maxLines == 0)
        #expect(block.overflow == "visible")
        #expect(block.sizingMode == "wrap")
        #expect(block.spans.isEmpty)
        #expect(shadow == nil)
    }

    @Test("text parser clamps decoration thickness boundaries to [1, 8]")
    func parserClampsDecorationThickness() throws {
        let widget = try parsedText([
            "spans": [
                ["text": "Max", "decoration": "underline", "decorationThickness": 99],
                ["text": "Min", "decoration": "underline", "decorationThickness": -5]
            ]
        ])
        guard case .text(_, let block, _) = widget else {
            Issue.record("Expected a parsed text widget")
            return
        }
        #expect(block.spans[0].decorationThickness == 8)
        #expect(block.spans[1].decorationThickness == 1)
    }

    @Test("text parser clamps decoration offset boundaries to [-16, 16]")
    func parserClampsDecorationOffset() throws {
        let widget = try parsedText([
            "spans": [
                ["text": "Min", "decoration": "underline", "decorationOffset": -40],
                ["text": "Max", "decoration": "underline", "decorationOffset": 50]
            ]
        ])
        guard case .text(_, let block, _) = widget else {
            Issue.record("Expected a parsed text widget")
            return
        }
        #expect(block.spans[0].decorationOffset == -16)
        #expect(block.spans[1].decorationOffset == 16)
    }

    @Test("text parser ignores empty and blank spans safely")
    func parserIgnoresEmptySpans() throws {
        let widget = try parsedText([
            "spans": [
                ["text": ""],
                ["text": "Valid"],
                ["text": ""]
            ]
        ])

        guard case .text(_, let block, _) = widget else {
            Issue.record("Expected a parsed text widget")
            return
        }

        #expect(block.spans.count == 1)
        #expect(block.spans[0].text == "Valid")
    }

    // MARK: - 3. Mathematical & Layout Oracles

    @Test("canvasGlyphShadowBlurRadius converts the combined blur + spread, floored at 0.1")
    func glyphShadowBlurRadiusOracle() {
        func sigma(_ combined: CGFloat) -> CGFloat { combined * 0.57735 + 0.5 }
        #expect(abs(canvasGlyphShadowBlurRadius(blur: 4, spread: 0) - sigma(4)) < 0.0001)
        #expect(abs(canvasGlyphShadowBlurRadius(blur: 4, spread: 3) - sigma(7)) < 0.0001)
        #expect(abs(canvasGlyphShadowBlurRadius(blur: 0, spread: 5) - sigma(5)) < 0.0001)
        #expect(abs(canvasGlyphShadowBlurRadius(blur: 0, spread: 0) - sigma(0.1)) < 0.0001)
        #expect(abs(canvasGlyphShadowBlurRadius(blur: 4, spread: -100) - sigma(0.1)) < 0.0001)
    }

    @Test("canvasGlyphShadowOutsets returns zero for nil or zero shadow")
    func glyphShadowOutsetsZeroOrNil() {
        #expect(canvasGlyphShadowOutsets(shadow: nil) == .zero)

        let zeroShadow = CampaignCanvasShadow(
            color: .literal("#00000000"), blur: 0, spread: 0, offsetX: 0, offsetY: 0)
        #expect(canvasGlyphShadowOutsets(shadow: zeroShadow) == .zero)
    }

    @Test("canvasGlyphShadowOutsets calculates symmetrical padding when offsets are zero")
    func glyphShadowOutsetsSymmetric() {
        let symShadow = CampaignCanvasShadow(
            color: .literal("#000000FF"), blur: 5, spread: 0, offsetX: 0, offsetY: 0)
        let outsets = canvasGlyphShadowOutsets(shadow: symShadow)
        #expect(outsets.top > 0)
        #expect(outsets.top == outsets.bottom)
        #expect(outsets.left == outsets.right)
    }

    @Test("canvasGlyphShadowOutsets shifts directional drawing padding based on offsets")
    func glyphShadowOutsetsDirectional() {
        let rightShadow = CampaignCanvasShadow(
            color: .literal("#000000FF"), blur: 5, spread: 0, offsetX: 10, offsetY: 0)
        let outsetsRight = canvasGlyphShadowOutsets(shadow: rightShadow)
        #expect(outsetsRight.right > outsetsRight.left)

        let downShadow = CampaignCanvasShadow(
            color: .literal("#000000FF"), blur: 5, spread: 0, offsetX: 0, offsetY: 10)
        let outsetsDown = canvasGlyphShadowOutsets(shadow: downShadow)
        #expect(outsetsDown.bottom > outsetsDown.top)
    }

    @Test("uiTextAlignment maps CampaignCanvasHorizontalAlign directly to NSTextAlignment")
    func textAlignmentMappingOracle() {
        #expect(CampaignCanvasHorizontalAlign.left.uiTextAlignment == .left)
        #expect(CampaignCanvasHorizontalAlign.center.uiTextAlignment == .center)
        #expect(CampaignCanvasHorizontalAlign.right.uiTextAlignment == .right)
    }

    @Test("CampaignCanvasTextBlock.alignment maps horizontal and vertical pairs to SwiftUI Alignment")
    func textBlockAlignmentMappingOracle() {
        let tl = CampaignCanvasTextBlock(
            horizontalAlign: .left, textAlign: .left, verticalAlign: .top,
            maxLines: 0, overflow: "visible", sizingMode: "wrap", spans: [])
        #expect(tl.alignment == Alignment(horizontal: .leading, vertical: .top))

        let cc = CampaignCanvasTextBlock(
            horizontalAlign: .center, textAlign: .center, verticalAlign: .center,
            maxLines: 0, overflow: "visible", sizingMode: "wrap", spans: [])
        #expect(cc.alignment == Alignment(horizontal: .center, vertical: .center))

        let br = CampaignCanvasTextBlock(
            horizontalAlign: .right, textAlign: .right, verticalAlign: .bottom,
            maxLines: 0, overflow: "visible", sizingMode: "wrap", spans: [])
        #expect(br.alignment == Alignment(horizontal: .trailing, vertical: .bottom))
    }

    // MARK: - 4. Rich Text Link Routing

    @Test("rich text coordinator triggers onSpan callback for in-bounds digia-canvas link")
    func richTextCoordinatorTriggersOnSpanForValidCanvasScheme() {
        let coordinator = CanvasRichText.Coordinator()
        let span = CampaignCanvasTextSpan(
            text: "Terms",
            typography: nil,
            color: nil,
            highlightColor: nil,
            italic: false,
            decoration: .underline,
            decorationColor: nil,
            decorationThickness: nil,
            actions: [.openUrl("https://example.com/terms")]
        )
        coordinator.spans = [span]

        var triggeredSpan: CampaignCanvasTextSpan?
        coordinator.onSpan = { triggeredSpan = $0 }

        let handled = coordinator.textView(
            UITextView(),
            shouldInteractWith: URL(string: "digia-canvas://span/0")!,
            in: NSRange(location: 0, length: 0),
            interaction: .invokeDefaultAction
        )

        #expect(handled == false)
        #expect(triggeredSpan == span)
    }

    @Test("rich text coordinator ignores out-of-bounds link index")
    func richTextCoordinatorIgnoresOutOfBoundsIndex() {
        let coordinator = CanvasRichText.Coordinator()
        coordinator.spans = [
            CampaignCanvasTextSpan(text: "Single", typography: nil, color: nil, highlightColor: nil, italic: false, decoration: .none, decorationColor: nil, decorationThickness: nil, actions: [])
        ]

        var triggered = false
        coordinator.onSpan = { _ in triggered = true }

        let handled = coordinator.textView(
            UITextView(),
            shouldInteractWith: URL(string: "digia-canvas://span/99")!,
            in: NSRange(location: 0, length: 0),
            interaction: .invokeDefaultAction
        )

        #expect(handled == false)
        #expect(triggered == false)
    }

    @Test("rich text coordinator ignores foreign URL scheme")
    func richTextCoordinatorIgnoresForeignScheme() {
        let coordinator = CanvasRichText.Coordinator()
        coordinator.spans = [
            CampaignCanvasTextSpan(text: "External", typography: nil, color: nil, highlightColor: nil, italic: false, decoration: .none, decorationColor: nil, decorationThickness: nil, actions: [])
        ]

        var triggered = false
        coordinator.onSpan = { _ in triggered = true }

        let handled = coordinator.textView(
            UITextView(),
            shouldInteractWith: URL(string: "https://example.com/terms")!,
            in: NSRange(location: 0, length: 0),
            interaction: .invokeDefaultAction
        )

        #expect(handled == false)
        #expect(triggered == false)
    }

    @Test("rich text coordinator ignores non-numeric canvas link path")
    func richTextCoordinatorIgnoresNonNumericPath() {
        let coordinator = CanvasRichText.Coordinator()
        coordinator.spans = [
            CampaignCanvasTextSpan(text: "Invalid", typography: nil, color: nil, highlightColor: nil, italic: false, decoration: .none, decorationColor: nil, decorationThickness: nil, actions: [])
        ]

        var triggered = false
        coordinator.onSpan = { _ in triggered = true }

        let handled = coordinator.textView(
            UITextView(),
            shouldInteractWith: URL(string: "digia-canvas://span/notanumber")!,
            in: NSRange(location: 0, length: 0),
            interaction: .invokeDefaultAction
        )

        #expect(handled == false)
        #expect(triggered == false)
    }

    // MARK: - Private Helpers

    private func parsedText(
        _ props: [String: Any],
        box: [String: Any] = [:]
    ) throws -> CampaignCanvasWidget {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 200,
            "children": [
                [
                    "kind": "widget",
                    "id": "t1",
                    "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
                    "widget": [
                        "type": "digia/text",
                        "containerProps": box,
                        "props": props
                    ]
                ]
            ]
        ])
        guard case .widget(_, _, let widget) = canvas.children.first else {
            throw DesignTokenError.invalid("Failed to parse text widget")
        }
        return widget
    }

    private func mount(
        text: CampaignCanvasWidget,
        isDark: Bool = false,
        variables: VariableContext? = nil,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void = { _ in }
    ) -> UIWindow {
        let canvas = CampaignCanvas(
            version: 2,
            width: 360,
            height: 120,
            background: .solid(.literal("#FFFFFFFF")),
            children: [
                .widget(id: "test-text", rect: CampaignCanvasRect(x: 0, y: 0, width: 360, height: 120), widget: text)
            ]
        )
        return mount(canvas: canvas, isDark: isDark, variables: variables, onAction: onAction)
    }

    private func mount(
        canvas: CampaignCanvas,
        isDark: Bool = false,
        variables: VariableContext? = nil,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void = { _ in }
    ) -> UIWindow {
        ComponentTestHost.mountCanvas(
            canvas,
            isDark: isDark,
            variables: variables,
            onAction: onAction
        ).window
    }

}
}
