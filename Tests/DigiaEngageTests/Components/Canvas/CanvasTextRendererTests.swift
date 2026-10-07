import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas text renderer", .serialized, .tags(.canvas, .component))
struct CanvasTextRendererTests {

    // MARK: - 1. Parser & Schema Preservation

    @Test("text parser preserves single span with full typography, decorations, and colors")
    func parserPreservesSingleSpan() throws {
        let widget = try parsedText([
            "horizontalAlign": "center",
            "textAlign": "center",
            "verticalAlign": "center",
            "maxLines": 3,
            "overflow": "ellipsis",
            "sizingMode": "fixed",
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
            ],
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

        #expect(shadow?.color.lightHex == "#00000033")
        #expect(shadow?.blur == 8)
        #expect(shadow?.spread == 2)
        #expect(shadow?.offsetX == 1)
        #expect(shadow?.offsetY == 3)
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

    @Test("canvasGlyphShadowBlurRadius calculates exact Gaussian sigma with spread and zero clamping")
    func glyphShadowBlurRadiusOracle() {
        // Zero blur
        #expect(canvasGlyphShadowBlurRadius(blur: 0, spread: 0) == 0)
        #expect(canvasGlyphShadowBlurRadius(blur: 0, spread: 5) == 5)
        #expect(canvasGlyphShadowBlurRadius(blur: 0, spread: -3) == 0)

        // Positive blur: 2 * (blur * 0.57735 + 0.5) + spread
        let expectedForBlur4 = 2.0 * (4.0 * 0.57735 + 0.5)
        #expect(abs(canvasGlyphShadowBlurRadius(blur: 4, spread: 0) - expectedForBlur4) < 0.0001)

        let expectedForBlur4WithSpread = expectedForBlur4 + 3.0
        #expect(abs(canvasGlyphShadowBlurRadius(blur: 4, spread: 3) - expectedForBlur4WithSpread) < 0.0001)

        // Large negative spread clamps to zero
        #expect(canvasGlyphShadowBlurRadius(blur: 4, spread: -100) == 0)
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

    // MARK: - 5. Visual Golden

    @Test("text renderer matches visual golden", .tags(.golden))
    func textRendererVisualGolden() throws {
        let textWidget = try parsedText([
            "textAlign": "center",
            "horizontalAlign": "center",
            "verticalAlign": "center",
            "spans": [
                [
                    "text": "Special Announcement\n",
                    "typography": [
                        "fontSize": 20,
                        "fontWeight": "W700",
                        "lineHeight": 26
                    ],
                    "color": "#FF1E293B"
                ],
                [
                    "text": "Get 20% off your next purchase with code DIGIA.",
                    "typography": [
                        "fontSize": 14,
                        "fontWeight": "W400",
                        "lineHeight": 20
                    ],
                    "color": "#FF64748B"
                ]
            ]
        ], box: [
            "fill": ["type": "solid", "color": "#FFF8FAFC"],
            "borderRadius": 12,
            "padding": ["top": 16, "bottom": 16, "left": 20, "right": 20]
        ])

        let window = mount(text: textWidget)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("text renderer handles truncation and maxLines with ellipsis", .tags(.golden))
    func textRendererTruncationWithEllipsisVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 140,
            "background": ["type": "solid", "color": "#FFF1F5F9"],
            "children": [
                [
                    "kind": "widget",
                    "id": "single-line-truncation",
                    "rect": ["x": 0.05, "y": 0.1, "width": 0.9, "height": 0.35],
                    "widget": [
                        "type": "digia/text",
                        "containerProps": [
                            "fill": ["type": "solid", "color": "#FFFFFFFF"],
                            "borderRadius": 8,
                            "padding": ["top": 8, "bottom": 8, "left": 12, "right": 12],
                            "border": ["color": "#FFE2E8F0", "width": 1]
                        ],
                        "props": [
                            "maxLines": 1,
                            "overflow": "ellipsis",
                            "spans": [
                                [
                                    "text": "Flash Sale: Unbelievable discounts across all departments available for the next 24 hours only!",
                                    "typography": ["fontSize": 14, "fontWeight": "W700"],
                                    "color": "#FF0F172A"
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "two-line-truncation",
                    "rect": ["x": 0.05, "y": 0.52, "width": 0.9, "height": 0.42],
                    "widget": [
                        "type": "digia/text",
                        "containerProps": [
                            "fill": ["type": "solid", "color": "#FFFFFFFF"],
                            "borderRadius": 8,
                            "padding": ["top": 8, "bottom": 8, "left": 12, "right": 12],
                            "border": ["color": "#FFE2E8F0", "width": 1]
                        ],
                        "props": [
                            "maxLines": 2,
                            "overflow": "ellipsis",
                            "spans": [
                                [
                                    "text": "Offer Terms: Promotional vouchers cannot be combined with any other discount or reward point redemption. Valid while supplies last. Subject to standard terms of purchase and merchant review.",
                                    "typography": ["fontSize": 12, "fontWeight": "W400", "lineHeight": 16],
                                    "color": "#FF64748B"
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        let window = mount(canvas: canvas)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("text renderer renders rich decorations including highlights, underlines, and strikethroughs", .tags(.golden))
    func textRendererRichDecorationsVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 120,
            "background": ["type": "solid", "color": "#FFFFFFFF"],
            "children": [
                [
                    "kind": "widget",
                    "id": "rich-text-decorations",
                    "rect": ["x": 0.05, "y": 0.1, "width": 0.9, "height": 0.8],
                    "widget": [
                        "type": "digia/text",
                        "containerProps": [
                            "fill": ["type": "solid", "color": "#FFF8FAFC"],
                            "borderRadius": 12,
                            "padding": ["top": 12, "bottom": 12, "left": 16, "right": 16],
                            "border": ["color": "#FFE2E8F0", "width": 1]
                        ],
                        "props": [
                            "maxLines": 3,
                            "spans": [
                                [
                                    "text": "Special Deal: ",
                                    "typography": ["fontSize": 14, "fontWeight": "W700"],
                                    "color": "#FF0F172A"
                                ],
                                [
                                    "text": "Limited Stock ",
                                    "typography": ["fontSize": 13, "fontWeight": "W600"],
                                    "color": "#FF854D0E",
                                    "highlightColor": "#FFFEF08A"
                                ],
                                [
                                    "text": "was $99.99 ",
                                    "typography": ["fontSize": 12, "fontWeight": "W400"],
                                    "color": "#FFDC2626",
                                    "decoration": "lineThrough",
                                    "decorationColor": "#FFDC2626",
                                    "decorationThickness": 1.5
                                ],
                                [
                                    "text": "now $49.99. ",
                                    "typography": ["fontSize": 14, "fontWeight": "W800"],
                                    "color": "#FF16A34A"
                                ],
                                [
                                    "text": "Shop today!",
                                    "typography": ["fontSize": 13, "fontWeight": "W500"],
                                    "color": "#FF2563EB",
                                    "italic": true,
                                    "decoration": "underline",
                                    "decorationColor": "#FF2563EB",
                                    "decorationThickness": 2,
                                    "decorationOffset": 3
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        let window = mount(canvas: canvas)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("text renderer renders right-aligned and bottom-aligned text extremes", .tags(.golden))
    func textRendererAlignmentExtremesVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 110,
            "background": ["type": "solid", "color": "#FF0F172A"],
            "children": [
                [
                    "kind": "widget",
                    "id": "aligned-text",
                    "rect": ["x": 0.05, "y": 0.08, "width": 0.9, "height": 0.84],
                    "widget": [
                        "type": "digia/text",
                        "containerProps": [
                            "fill": ["type": "solid", "color": "#FF1E293B"],
                            "borderRadius": 10,
                            "padding": ["top": 10, "bottom": 10, "left": 14, "right": 14],
                            "border": ["color": "#FF334155", "width": 1]
                        ],
                        "props": [
                            "horizontalAlign": "right",
                            "textAlign": "right",
                            "verticalAlign": "bottom",
                            "spans": [
                                [
                                    "text": "Premium Tier Member\n",
                                    "typography": ["fontSize": 15, "fontWeight": "W700"],
                                    "color": "#FFF8FAFC"
                                ],
                                [
                                    "text": "Account ID: #849204 • Verified",
                                    "typography": ["fontSize": 12, "fontWeight": "W400"],
                                    "color": "#FF94A3B8"
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        let window = mount(canvas: canvas)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
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
        var stage = CampaignCanvasStage(
            canvas: canvas,
            authoredCornerRadius: 0,
            isDark: isDark,
            showBackground: true,
            onAction: onAction
        )
        stage.animateWidgetsOnAppear = false
        var hostedView = AnyView(stage.ignoresSafeArea())
        if let variables {
            hostedView = AnyView(hostedView.environment(\.digiaVariables, variables))
        }
        let controller = ComponentTestHost.makeComponentHost(
            rootView: hostedView,
            size: CGSize(width: canvas.width, height: canvas.height),
            backgroundColor: .white
        )
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: controller.view.bounds)
        }
        window.frame = controller.view.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        ComponentTestHost.drainRunLoop(for: 0.05)
        return window
    }

    private func unmount(_ window: UIWindow) {
        if let root = window.rootViewController {
            root.beginAppearanceTransition(false, animated: false)
            root.endAppearanceTransition()
        }
        window.rootViewController = nil
        window.isHidden = true
        window.resignKey()
        ComponentTestHost.drainRunLoop(for: 0.02)
    }
}
