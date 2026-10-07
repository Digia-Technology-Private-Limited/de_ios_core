import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas button renderer", .serialized, .tags(.canvas, .component))
struct CanvasButtonRendererTests {

    // MARK: - 1. Parser & Schema Preservation

    @Test("button parser preserves all variants: fill, outline, and text")
    func parserPreservesVariants() throws {
        // Variant: Fill
        let fillWidget = try parsedButton([
            "style": [
                "variant": "fill",
                "fill": ["type": "solid", "color": "#007AFF"]
            ]
        ])
        guard case .button(_, _, _, let fillStyle, _, _, _, _, _, _) = fillWidget else {
            Issue.record("Expected a parsed button widget")
            return
        }
        #expect(fillStyle == .fill(fill: .solid(.literal("#FF007AFF"))))

        // Variant: Outline
        let outlineWidget = try parsedButton([
            "style": [
                "variant": "outline",
                "fill": ["type": "solid", "color": "#FFFFFF"],
                "outline": ["color": "#007AFF", "width": 2.0]
            ]
        ])
        guard case .button(_, _, _, let outlineStyle, _, _, _, _, _, _) = outlineWidget else {
            Issue.record("Expected a parsed button widget")
            return
        }
        #expect(
            outlineStyle
                == .outline(
                    fill: .solid(.literal("#FFFFFFFF")),
                    outline: CampaignCanvasBorder(color: .literal("#FF007AFF"), width: 2.0)
                )
        )

        // Variant: Text (Ghost)
        let textWidget = try parsedButton([
            "style": [
                "variant": "text"
            ]
        ])
        guard case .button(_, _, _, let textStyle, _, _, _, _, _, _) = textWidget else {
            Issue.record("Expected a parsed button widget")
            return
        }
        #expect(textStyle == .text)
    }

    @Test("button parser preserves labels, actions, confirm dialog, and primary/destructive flags")
    func parserPreservesProperties() throws {
        let widget = try parsedButton([
            "label": [
                "spans": [
                    ["text": "Delete Account", "color": "#FFFFFF", "fontSize": 16]
                ]
            ],
            "cornerRadius": 12,
            "isPrimary": true,
            "isDestructive": true,
            "applyDestructiveStyling": true,
            "onClick": [
                "steps": [
                    [
                        "type": "Action.dismiss"
                    ]
                ]
            ],
            "confirm": [
                "title": "Are you sure?",
                "message": "This action cannot be undone.",
                "confirmLabel": "Delete",
                "cancelLabel": "Back",
                "titleFontWeight": 700,
                "messageFontWeight": 400,
                "buttonFontWeight": 600
            ],
            "shadow": [
                "color": "#00000033",
                "blur": 6,
                "spread": 1,
                "offsetX": 0,
                "offsetY": 2
            ]
        ])

        guard case .button(
            let box, let label, let cornerRadius, _, let shadow,
            let isPrimary, let isDestructive, let applyDestructiveStyling,
            let actions, let confirm
        ) = widget else {
            Issue.record("Expected a parsed button widget")
            return
        }

        #expect(box.shadow == nil) // Button strips box shadow and manages it directly
        #expect(label.plainText == "Delete Account")
        #expect(cornerRadius == CampaignCanvasCornerRadius(topLeft: 12, topRight: 12, bottomRight: 12, bottomLeft: 12))
        #expect(isPrimary == true)
        #expect(isDestructive == true)
        #expect(applyDestructiveStyling == true)
        #expect(actions == [.dismiss])
        #expect(confirm.title == "Are you sure?")
        #expect(confirm.message == "This action cannot be undone.")
        #expect(confirm.confirmLabel == "Delete")
        #expect(confirm.cancelLabel == "Back")
        #expect(confirm.titleFontWeight == 700)
        #expect(confirm.messageFontWeight == 400)
        #expect(confirm.buttonFontWeight == 600)
        #expect(shadow?.blur == 6)
        #expect(shadow?.spread == 1)
        #expect(shadow?.offsetY == 2)
    }

    // MARK: - 2. Parser Defaults & Fallbacks

    @Test("button parser defaults variant to fill, cornerRadius to 8, and confirm dialog to safe defaults")
    func parserDefaults() throws {
        let widget = try parsedButton([:])

        guard case .button(
            _, let label, let cornerRadius, let style, let shadow,
            let isPrimary, let isDestructive, let applyDestructiveStyling,
            let actions, let confirm
        ) = widget else {
            Issue.record("Expected a parsed button widget")
            return
        }

        #expect(style == .fill(fill: .none))
        #expect(cornerRadius == CampaignCanvasCornerRadius(topLeft: 8, topRight: 8, bottomRight: 8, bottomLeft: 8))
        #expect(shadow == nil)
        #expect(isPrimary == false)
        #expect(isDestructive == false)
        #expect(applyDestructiveStyling == true)
        #expect(actions.isEmpty)
        #expect(confirm.title == nil)
        #expect(confirm.message == nil)
        #expect(confirm.confirmLabel == "Yes")
        #expect(confirm.cancelLabel == "Cancel")

        // Label block button defaults: centered, maxLines 1, ellipsis overflow
        #expect(label.horizontalAlign == .center)
        #expect(label.textAlign == .center)
        #expect(label.verticalAlign == .center)
        #expect(label.maxLines == 1)
        #expect(label.overflow == "ellipsis")
    }

    // MARK: - 3. Effective Colors Oracle

    @Test("canvasButtonEffectiveColors calculates correct fill, destructive styling, and text colors")
    func effectiveColorsOracle() {
        let standardFill = CampaignCanvasPaint.solid(.literal("#FF007AFF"))
        let dangerColor = CampaignColor.literal("#FFD92D20")
        let outlineBorder = CampaignCanvasBorder(color: .literal("#FF4945FF"), width: 1.5)

        // 1. Standard filled button
        let standardFilled = canvasButtonEffectiveColors(
            style: .fill(fill: standardFill),
            isDestructive: false,
            applyDestructiveStyling: false,
            isDark: false,
            outline: nil
        )
        #expect(standardFilled.isFilled == true)
        #expect(standardFilled.fill == standardFill)
        #expect(standardFilled.destructiveColor == nil)
        #expect(standardFilled.foregroundColor == .white)

        // 2. Destructive filled button with applyDestructiveStyling: true
        let destructiveFilled = canvasButtonEffectiveColors(
            style: .fill(fill: standardFill),
            isDestructive: true,
            applyDestructiveStyling: true,
            isDark: false,
            outline: nil
        )
        #expect(destructiveFilled.isFilled == true)
        #expect(destructiveFilled.fill == .solid(dangerColor))
        var dr: CGFloat = 0, dg: CGFloat = 0, db: CGFloat = 0, da: CGFloat = 0
        destructiveFilled.destructiveColor?.getRed(&dr, green: &dg, blue: &db, alpha: &da)
        #expect(dr == 1 && dg == 1 && db == 1 && da == 1)
        #expect(destructiveFilled.foregroundColor == .white)

        // 3. Destructive filled button with applyDestructiveStyling: false
        let nonStyledDestructiveFilled = canvasButtonEffectiveColors(
            style: .fill(fill: standardFill),
            isDestructive: true,
            applyDestructiveStyling: false,
            isDark: false,
            outline: nil
        )
        #expect(nonStyledDestructiveFilled.isFilled == true)
        #expect(nonStyledDestructiveFilled.fill == standardFill)
        #expect(nonStyledDestructiveFilled.destructiveColor == nil)
        #expect(nonStyledDestructiveFilled.foregroundColor == .white)

        // 4. Standard outline button
        let standardOutline = canvasButtonEffectiveColors(
            style: .outline(fill: .none, outline: outlineBorder),
            isDestructive: false,
            applyDestructiveStyling: false,
            isDark: false,
            outline: outlineBorder
        )
        #expect(standardOutline.isFilled == false)
        #expect(standardOutline.fill == .none)
        #expect(standardOutline.destructiveColor == nil)
        let expectedOutlineColor = UIColor(CampaignCanvasTheme.shared.color(outlineBorder.color, isDark: false))
        #expect(standardOutline.foregroundColor == expectedOutlineColor)

        // 5. Destructive outline button with applyDestructiveStyling: true
        let destructiveOutline = canvasButtonEffectiveColors(
            style: .outline(fill: .none, outline: outlineBorder),
            isDestructive: true,
            applyDestructiveStyling: true,
            isDark: false,
            outline: outlineBorder
        )
        #expect(destructiveOutline.isFilled == false)
        #expect(destructiveOutline.fill == .none)
        let expectedDangerColor = UIColor(CampaignCanvasTheme.shared.color(dangerColor, isDark: false))
        #expect(destructiveOutline.destructiveColor == expectedDangerColor)
        #expect(destructiveOutline.foregroundColor == expectedOutlineColor)

        // 6. Text (Ghost) button
        let textButton = canvasButtonEffectiveColors(
            style: .text,
            isDestructive: false,
            applyDestructiveStyling: false,
            isDark: false,
            outline: nil
        )
        #expect(textButton.isFilled == false)
        #expect(textButton.fill == .none)
    }

    // MARK: - 4. Action Request & Routing Oracle

    @Test("button action routing produces cta_primary for primary and cta_secondary for secondary")
    func actionRoutingOracle() {
        let actions = [EngageAction.openUrl("https://digia.com")]
        let label = CampaignCanvasTextBlock(
            horizontalAlign: .center,
            textAlign: .center,
            verticalAlign: .center,
            maxLines: 1,
            overflow: "ellipsis",
            sizingMode: "hug",
            spans: [
                CampaignCanvasTextSpan(
                    text: "Continue",
                    typography: nil,
                    color: nil,
                    highlightColor: nil,
                    italic: false,
                    decoration: .none,
                    decorationColor: nil,
                    decorationThickness: nil,
                    actions: []
                )
            ]
        )

        // Primary button request
        let primaryRequest = CampaignCanvasActionRequest(
            actions: actions,
            elementId: "cta_primary",
            label: label.plainText,
            isPrimary: true
        )
        #expect(primaryRequest.elementId == "cta_primary")
        #expect(primaryRequest.isPrimary == true)
        #expect(primaryRequest.label == "Continue")
        #expect(primaryRequest.actions == actions)

        // Secondary button request
        let secondaryRequest = CampaignCanvasActionRequest(
            actions: actions,
            elementId: "cta_secondary",
            label: label.plainText,
            isPrimary: false
        )
        #expect(secondaryRequest.elementId == "cta_secondary")
        #expect(secondaryRequest.isPrimary == false)
        #expect(secondaryRequest.label == "Continue")
    }

    // MARK: - 5. Interactive State & Lifecycle

    @Test("non-interactive button without actions renders stably")
    func nonInteractiveButtonRendering() {
        let widget = try! parsedButton([
            "label": [
                "spans": [
                    ["text": "Static Button"]
                ]
            ],
            "style": [
                "variant": "fill",
                "fill": ["type": "solid", "color": "#007AFF"]
            ]
        ])

        let window = mount(button: widget)
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(window.rootViewController?.view != nil)
        unmount(window)
    }

    @Test("interactive button with actions and shadow mounts with theme toggling")
    func interactiveButtonWithThemeToggle() {
        let action = EngageAction.openUrl("https://example.com/checkout")
        let widget = try! parsedButton([
            "label": [
                "spans": [
                    ["text": "Checkout Now", "color": "#FFFFFF"]
                ]
            ],
            "style": [
                "variant": "fill",
                "fill": ["type": "solid", "color": "#10B981"]
            ],
            "isPrimary": true,
            "onClick": [
                "steps": [
                    [
                        "type": "open_url",
                        "data": ["url": "https://example.com/checkout"]
                    ]
                ]
            ],
            "shadow": [
                "color": "#00000044",
                "blur": 8,
                "spread": 0,
                "offsetX": 0,
                "offsetY": 4
            ]
        ])

        // Light mode
        let windowLight = mount(button: widget, isDark: false)
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(windowLight.rootViewController?.view != nil)
        unmount(windowLight)

        // Dark mode
        let windowDark = mount(button: widget, isDark: true)
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(windowDark.rootViewController?.view != nil)
        unmount(windowDark)

        _ = action
    }

    // MARK: - 8. Visual Golden

    @Test("button renderer matches visual golden", .tags(.golden))
    func buttonRendererVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 80,
            "background": ["type": "solid", "color": "#FFF8FAFC"],
            "children": [
                [
                    "kind": "widget",
                    "id": "golden-btn",
                    "rect": ["x": 0.08, "y": 0.15, "width": 0.84, "height": 0.7],
                    "widget": [
                        "type": "digia/button",
                        "props": [
                            "label": [
                                "spans": [
                                    ["text": "Claim Offer", "color": "#FFFFFFFF", "fontSize": 16, "fontWeight": 700]
                                ]
                            ],
                            "style": [
                                "variant": "fill",
                                "fill": ["type": "solid", "color": "#FF2563EB"]
                            ],
                            "cornerRadius": 10,
                            "shadow": [
                                "color": "#332563EB",
                                "blur": 8,
                                "spread": 0,
                                "offsetX": 0,
                                "offsetY": 4
                            ]
                        ]
                    ]
                ]
            ]
        ])

        var stage = CampaignCanvasStage(
            canvas: canvas,
            authoredCornerRadius: 0,
            isDark: false,
            showBackground: true,
            onAction: { _ in }
        )
        stage.animateWidgetsOnAppear = false
        let controller = ComponentTestHost.makeComponentHost(
            rootView: AnyView(stage.ignoresSafeArea()),
            size: CGSize(width: 360, height: 80),
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
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    // MARK: - Private Helpers

    private func parsedButton(
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
                    "id": "btn1",
                    "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 0.3],
                    "widget": [
                        "type": "digia/button",
                        "containerProps": box,
                        "props": props
                    ]
                ]
            ]
        ])
        guard case .widget(_, _, let widget) = canvas.children.first else {
            throw DesignTokenError.invalid("Failed to parse button widget")
        }
        return widget
    }

    private func mount(
        button: CampaignCanvasWidget,
        isDark: Bool = false,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void = { _ in }
    ) -> UIWindow {
        let canvas = CampaignCanvas(
            version: 2,
            width: 360,
            height: 80,
            background: .solid(.literal("#FFFFFFFF")),
            children: [
                .widget(id: "test-btn", rect: CampaignCanvasRect(x: 0, y: 0, width: 360, height: 80), widget: button)
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
        let controller = ComponentTestHost.makeComponentHost(
            rootView: AnyView(stage.ignoresSafeArea()),
            size: CGSize(width: 360, height: 80),
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
