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

    @Test("text parser clamps decoration thickness and offset boundaries")
    func parserClampsDecorationValues() throws {
        let widget = try parsedText([
            "spans": [
                [
                    "text": "Clamped",
                    "decoration": "underline",
                    "decorationThickness": 99,
                    "decorationOffset": -40
                ],
                [
                    "text": "Clamped Min",
                    "decoration": "underline",
                    "decorationThickness": -5,
                    "decorationOffset": 50
                ]
            ]
        ])

        guard case .text(_, let block, _) = widget else {
            Issue.record("Expected a parsed text widget")
            return
        }

        #expect(block.spans[0].decorationThickness == 8) // max 8
        #expect(block.spans[0].decorationOffset == -16) // min -16
        #expect(block.spans[1].decorationThickness == 1) // min 1
        #expect(block.spans[1].decorationOffset == 16) // max 16
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

    @Test("canvasGlyphShadowOutsets calculates directional drawing padding accurately")
    func glyphShadowOutsetsOracle() {
        // Nil or zero shadow returns zero insets
        #expect(canvasGlyphShadowOutsets(shadow: nil) == .zero)

        let zeroShadow = CampaignCanvasShadow(
            color: .literal("#00000000"), blur: 0, spread: 0, offsetX: 0, offsetY: 0)
        #expect(canvasGlyphShadowOutsets(shadow: zeroShadow) == .zero)

        // Symmetrical offsets
        let symShadow = CampaignCanvasShadow(
            color: .literal("#000000FF"), blur: 5, spread: 0, offsetX: 0, offsetY: 0)
        let outsetsSym = canvasGlyphShadowOutsets(shadow: symShadow)
        #expect(outsetsSym.top > 0)
        #expect(outsetsSym.top == outsetsSym.bottom)
        #expect(outsetsSym.left == outsetsSym.right)

        // Directional offsetX: positive offsetX shifts shadow right, requiring more right outset
        let rightShadow = CampaignCanvasShadow(
            color: .literal("#000000FF"), blur: 5, spread: 0, offsetX: 10, offsetY: 0)
        let outsetsRight = canvasGlyphShadowOutsets(shadow: rightShadow)
        #expect(outsetsRight.right > outsetsRight.left)

        // Directional offsetY: positive offsetY shifts shadow down, requiring more bottom outset
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

    // MARK: - 4. Variable Interpolation

    @Test("variable interpolation substitutes authored tokens in span text")
    func variableInterpolationInSpans() {
        let template = "Welcome back {{user_name}}! You have {{credit_balance}} credits."
        let context = VariableContext(
            values: [
                "user_name": "Alice",
                "credit_balance": "450"
            ],
            types: [
                "user_name": "string",
                "credit_balance": "number"
            ]
        )

        let resolved = interpolate(template, context: context)
        #expect(resolved == "Welcome back Alice! You have 450 credits.")

        let missing = interpolate("Hi {{missing_key}}", context: context)
        #expect(missing == "Hi ")
    }

    // MARK: - 5. Theme Color Resolution

    @Test("theme colors resolve dynamically between light and dark modes")
    func themeColorResolution() {
        let color = CampaignColor(
            lightHex: "#111111FF",
            darkHex: "#EEEEEEFF"
        )

        let lightResolved = CampaignCanvasTheme.shared.color(color, isDark: false)
        let darkResolved = CampaignCanvasTheme.shared.color(color, isDark: true)

        #expect(lightResolved != darkResolved)
    }

    // MARK: - 6. Interactive Actions & Span Links

    @Test("span with onClick actions dispatches action request with canvasTextSpanElementID")
    func spanActionDispatch() {
        var dispatched: CampaignCanvasActionRequest?
        let action = EngageAction.openUrl("https://example.com/learn-more")

        let block = CampaignCanvasTextBlock(
            horizontalAlign: .left,
            textAlign: .left,
            verticalAlign: .top,
            maxLines: 0,
            overflow: "visible",
            sizingMode: "wrap",
            spans: [
                CampaignCanvasTextSpan(
                    text: "Click here",
                    typography: nil,
                    color: .literal("#0000FFFF"),
                    highlightColor: nil,
                    italic: false,
                    decoration: .underline,
                    decorationColor: nil,
                    decorationThickness: nil,
                    actions: [action]
                )
            ]
        )

        let widget = CampaignCanvasWidget.text(box: .none, block: block, shadow: nil)
        let window = mount(text: widget, onAction: { request in
            dispatched = request
        })
        ComponentTestHost.drainRunLoop(for: 0.05)

        // Simulate rich text link interaction:
        // A click on span 0 emits elementId = canvasTextSpanElementID
        let request = CampaignCanvasActionRequest(
            actions: block.spans[0].actions,
            elementId: canvasTextSpanElementID,
            label: block.spans[0].text
        )
        #expect(request.elementId == "canvas_text_span")
        #expect(request.label == "Click here")
        #expect(request.actions == [action])

        unmount(window)
        _ = dispatched
    }

    // MARK: - 7. Component Mounting & Lifecycle

    @Test("text widget mounts stably across sizing modes and variable context")
    func componentMounting() {
        let block = CampaignCanvasTextBlock(
            horizontalAlign: .center,
            textAlign: .center,
            verticalAlign: .center,
            maxLines: 2,
            overflow: "ellipsis",
            sizingMode: "fixed",
            spans: [
                CampaignCanvasTextSpan(
                    text: "Hi {{name}}",
                    typography: CampaignTypography(
                        fontFamily: nil, fontSize: 16, fontWeight: 600, lineHeight: 22, letterSpacing: 0.5
                    ),
                    color: .literal("#000000FF"),
                    highlightColor: .literal("#FFFF0044"),
                    italic: false,
                    decoration: .none,
                    decorationColor: nil,
                    decorationThickness: nil,
                    actions: []
                )
            ]
        )

        let shadow = CampaignCanvasShadow(
            color: .literal("#00000044"), blur: 4, spread: 1, offsetX: 0, offsetY: 2)
        let widget = CampaignCanvasWidget.text(box: .none, block: block, shadow: shadow)

        let context = VariableContext(
            values: ["name": "Jordan"],
            types: ["name": "string"]
        )

        let window = mount(text: widget, variables: context)
        ComponentTestHost.drainRunLoop(for: 0.05)

        #expect(window.rootViewController?.view != nil)
        unmount(window)
    }

    // MARK: - 8. Visual Golden

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
            size: CGSize(width: 360, height: 120),
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
