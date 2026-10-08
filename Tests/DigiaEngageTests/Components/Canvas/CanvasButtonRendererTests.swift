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

    enum StyleVariantCase: String, Sendable, CaseIterable {
        case fill
        case outline
        case text
    }

    @Test(
        "button parser preserves button style variants",
        arguments: StyleVariantCase.allCases
    )
    func parserPreservesStyleVariants(variant: StyleVariantCase) throws {
        switch variant {
        case .fill:
            let widget = try parsedButton([
                "style": [
                    "variant": "fill",
                    "fill": ["type": "solid", "color": "#007AFF"]
                ]
            ])
            guard case .button(_, _, _, let style, _, _, _, _, _, _) = widget else {
                Issue.record("Expected a parsed button widget")
                return
            }
            #expect(style == .fill(fill: .solid(.literal("#FF007AFF"))))
        case .outline:
            let widget = try parsedButton([
                "style": [
                    "variant": "outline",
                    "fill": ["type": "solid", "color": "#FFFFFF"],
                    "outline": ["color": "#007AFF", "width": 2.0]
                ]
            ])
            guard case .button(_, _, _, let style, _, _, _, _, _, _) = widget else {
                Issue.record("Expected a parsed button widget")
                return
            }
            #expect(
                style == .outline(
                    fill: .solid(.literal("#FFFFFFFF")),
                    outline: CampaignCanvasBorder(color: .literal("#FF007AFF"), width: 2.0)
                )
            )
        case .text:
            let widget = try parsedButton(["style": ["variant": "text"]])
            guard case .button(_, _, _, let style, _, _, _, _, _, _) = widget else {
                Issue.record("Expected a parsed button widget")
                return
            }
            #expect(style == .text)
        }
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

    // MARK: - 3. Effective Colors Oracle

    @Test("canvasButtonEffectiveColors calculates standard filled button colors")
    func effectiveColorsStandardFilled() {
        let standardFill = CampaignCanvasPaint.solid(.literal("#FF007AFF"))
        let colors = canvasButtonEffectiveColors(
            style: .fill(fill: standardFill),
            isDestructive: false,
            applyDestructiveStyling: false,
            isDark: false,
            outline: nil
        )
        #expect(colors.isFilled == true)
        #expect(colors.fill == standardFill)
        #expect(colors.destructiveColor == nil)
        #expect(colors.foregroundColor == .white)
    }

    @Test("canvasButtonEffectiveColors calculates destructive filled button with danger styling")
    func effectiveColorsDestructiveFilledStyled() {
        let standardFill = CampaignCanvasPaint.solid(.literal("#FF007AFF"))
        let dangerColor = CampaignColor.literal("#FFD92D20")
        let colors = canvasButtonEffectiveColors(
            style: .fill(fill: standardFill),
            isDestructive: true,
            applyDestructiveStyling: true,
            isDark: false,
            outline: nil
        )
        #expect(colors.isFilled == true)
        #expect(colors.fill == .solid(dangerColor))
        var dr: CGFloat = 0, dg: CGFloat = 0, db: CGFloat = 0, da: CGFloat = 0
        colors.destructiveColor?.getRed(&dr, green: &dg, blue: &db, alpha: &da)
        #expect(dr == 1 && dg == 1 && db == 1 && da == 1)
        #expect(colors.foregroundColor == .white)
    }

    @Test("canvasButtonEffectiveColors preserves authored fill for destructive filled button when styling is unstyled")
    func effectiveColorsDestructiveFilledUnstyled() {
        let standardFill = CampaignCanvasPaint.solid(.literal("#FF007AFF"))
        let colors = canvasButtonEffectiveColors(
            style: .fill(fill: standardFill),
            isDestructive: true,
            applyDestructiveStyling: false,
            isDark: false,
            outline: nil
        )
        #expect(colors.isFilled == true)
        #expect(colors.fill == standardFill)
        #expect(colors.destructiveColor == nil)
        #expect(colors.foregroundColor == .white)
    }

    @Test("canvasButtonEffectiveColors calculates standard outline button colors")
    func effectiveColorsStandardOutline() {
        let outlineBorder = CampaignCanvasBorder(color: .literal("#FF4945FF"), width: 1.5)
        let colors = canvasButtonEffectiveColors(
            style: .outline(fill: .none, outline: outlineBorder),
            isDestructive: false,
            applyDestructiveStyling: false,
            isDark: false,
            outline: outlineBorder
        )
        #expect(colors.isFilled == false)
        #expect(colors.fill == .none)
        #expect(colors.destructiveColor == nil)
        let expectedColor = UIColor(CampaignCanvasTheme.shared.color(outlineBorder.color, isDark: false))
        #expect(colors.foregroundColor == expectedColor)
    }

    @Test("canvasButtonEffectiveColors calculates destructive outline button with danger styling")
    func effectiveColorsDestructiveOutlineStyled() {
        let dangerColor = CampaignColor.literal("#FFD92D20")
        let outlineBorder = CampaignCanvasBorder(color: .literal("#FF4945FF"), width: 1.5)
        let colors = canvasButtonEffectiveColors(
            style: .outline(fill: .none, outline: outlineBorder),
            isDestructive: true,
            applyDestructiveStyling: true,
            isDark: false,
            outline: outlineBorder
        )
        #expect(colors.isFilled == false)
        #expect(colors.fill == .none)
        let expectedDangerColor = UIColor(CampaignCanvasTheme.shared.color(dangerColor, isDark: false))
        #expect(colors.destructiveColor == expectedDangerColor)
        let expectedOutlineColor = UIColor(CampaignCanvasTheme.shared.color(outlineBorder.color, isDark: false))
        #expect(colors.foregroundColor == expectedOutlineColor)
    }

    @Test("canvasButtonEffectiveColors calculates ghost text button with transparent background")
    func effectiveColorsTextGhost() {
        let colors = canvasButtonEffectiveColors(
            style: .text,
            isDestructive: false,
            applyDestructiveStyling: false,
            isDark: false,
            outline: nil
        )
        #expect(colors.isFilled == false)
        #expect(colors.fill == .none)
    }

    // MARK: - 4. Action Request & Routing Oracle

    // MARK: - 4. Action Request & Routing Oracle

    @Test(
        "canvasButtonActionRequest routes primary and secondary buttons with correct elementId and flags",
        arguments: [true, false]
    )
    func buttonActionRequestRouting(isPrimary: Bool) {
        let actions = [EngageAction.openUrl("https://digia.com")]
        let request = canvasButtonActionRequest(actions: actions, isPrimary: isPrimary, label: "Continue")
        #expect(request.isPrimary == isPrimary)
        #expect(request.elementId == (isPrimary ? "cta_primary" : "cta_secondary"))
        #expect(request.label == "Continue")
        #expect(request.actions == actions)
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

        let window = mount(canvas: canvas)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("button renderer handles outline style with custom border and text styling", .tags(.golden))
    func buttonRendererOutlineStyleVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 90,
            "background": ["type": "solid", "color": "#FFF8FAFC"],
            "children": [
                [
                    "kind": "widget",
                    "id": "outline-btn",
                    "rect": ["x": 0.08, "y": 0.18, "width": 0.84, "height": 0.64],
                    "widget": [
                        "type": "digia/button",
                        "props": [
                            "label": [
                                "spans": [
                                    ["text": "View Full Details", "color": "#FF2563EB", "fontSize": 16, "fontWeight": 700]
                                ]
                            ],
                            "style": [
                                "variant": "outline",
                                "fill": ["type": "solid", "color": "#00000000"],
                                "outline": [
                                    "width": 2,
                                    "color": "#FF2563EB"
                                ]
                            ],
                            "cornerRadius": 10
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

    @Test("button renderer handles ghost text style with no fill or border", .tags(.golden))
    func buttonRendererTextStyleVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 90,
            "background": ["type": "solid", "color": "#FFF8FAFC"],
            "children": [
                [
                    "kind": "widget",
                    "id": "text-btn",
                    "rect": ["x": 0.08, "y": 0.18, "width": 0.84, "height": 0.64],
                    "widget": [
                        "type": "digia/button",
                        "props": [
                            "label": [
                                "spans": [
                                    ["text": "Skip for Now", "color": "#FF64748B", "fontSize": 15, "fontWeight": 600]
                                ]
                            ],
                            "style": [
                                "variant": "text"
                            ],
                            "cornerRadius": 8
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

    @Test("button renderer handles destructive style with high-contrast styling", .tags(.golden))
    func buttonRendererDestructiveStyleVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 90,
            "background": ["type": "solid", "color": "#FFF8FAFC"],
            "children": [
                [
                    "kind": "widget",
                    "id": "destructive-btn",
                    "rect": ["x": 0.08, "y": 0.18, "width": 0.84, "height": 0.64],
                    "widget": [
                        "type": "digia/button",
                        "props": [
                            "label": [
                                "spans": [
                                    ["text": "Delete Account Permanently", "color": "#FFFFFFFF", "fontSize": 15, "fontWeight": 700]
                                ]
                            ],
                            "style": [
                                "variant": "fill",
                                "fill": ["type": "solid", "color": "#FFDC2626"]
                            ],
                            "cornerRadius": 8,
                            "isDestructive": true,
                            "applyDestructiveStyling": true,
                            "shadow": [
                                "color": "#33DC2626",
                                "blur": 8,
                                "spread": 0,
                                "offsetX": 0,
                                "offsetY": 3
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

    @Test("button renderer handles asymmetric corner radiuses and rich multi-span labels", .tags(.golden))
    func buttonRendererAsymmetricCornersVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 90,
            "background": ["type": "solid", "color": "#FF0F172A"],
            "children": [
                [
                    "kind": "widget",
                    "id": "asymmetric-btn",
                    "rect": ["x": 0.08, "y": 0.18, "width": 0.84, "height": 0.64],
                    "widget": [
                        "type": "digia/button",
                        "props": [
                            "label": [
                                "spans": [
                                    ["text": "Upgrade to Pro ", "color": "#FFFFFFFF", "fontSize": 15, "fontWeight": 700],
                                    ["text": "• SAVE 50%", "color": "#FFFEF08A", "fontSize": 13, "fontWeight": 800]
                                ]
                            ],
                            "style": [
                                "variant": "fill",
                                "fill": ["type": "solid", "color": "#FF4F46E5"]
                            ],
                            "cornerRadius": [
                                "topLeft": 24,
                                "topRight": 4,
                                "bottomRight": 24,
                                "bottomLeft": 4
                            ],
                            "shadow": [
                                "color": "#664F46E5",
                                "blur": 12,
                                "spread": 0,
                                "offsetX": 0,
                                "offsetY": 4
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

    // MARK: - 5. Interactive & Destructive Action Flow

    @Test("destructive button tap shows confirmation alert and emits nothing")
    func destructiveButtonTapShowsAlertAndEmitsNothing() throws {
        var actionsReceived: [CampaignCanvasActionRequest] = []
        let button = try parsedButton([
            "label": ["spans": [["text": "Delete Account"]]],
            "isDestructive": true,
            "onClick": ["steps": [["type": "Action.dismiss"]]],
            "confirm": [
                "title": "Delete Account?",
                "message": "This action cannot be undone.",
                "confirmLabel": "Delete",
                "cancelLabel": "Cancel"
            ]
        ])

        let window = mount(button: button, onAction: { actionsReceived.append($0) })
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated)

        let alert = presentedAlert(in: window)
        #expect(alert != nil)
        #expect(alert?.title == "Delete Account?")
        #expect(alert?.message == "This action cannot be undone.")
        #expect(actionsReceived.isEmpty)
    }

    @Test("non-destructive button tap emits action directly without alert")
    func nonDestructiveButtonTapEmitsOnce() throws {
        var actionsReceived: [CampaignCanvasActionRequest] = []
        let button = try parsedButton([
            "label": ["spans": [["text": "Continue"]]],
            "isDestructive": false,
            "isPrimary": true,
            "onClick": ["steps": [["type": "Action.dismiss"]]]
        ])

        let window = mount(button: button, onAction: { actionsReceived.append($0) })
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated)

        let alert = window.rootViewController?.presentedViewController as? UIAlertController
        #expect(alert == nil)
        #expect(actionsReceived.count == 1)
        #expect(actionsReceived.first?.elementId == "cta_primary")
        #expect(actionsReceived.first?.isPrimary == true)
        #expect(actionsReceived.first?.label == "Continue")
        #expect(actionsReceived.first?.actions == [.dismiss])
    }

    @Test("destructive alert confirm button emits action once")
    func destructiveAlertConfirmEmitsOnce() throws {
        var actionsReceived: [CampaignCanvasActionRequest] = []
        let button = try parsedButton([
            "label": ["spans": [["text": "Delete Account"]]],
            "isDestructive": true,
            "isPrimary": false,
            "onClick": ["steps": [["type": "Action.dismiss"]]],
            "confirm": [
                "title": "Delete?",
                "message": "Are you sure?",
                "confirmLabel": "Delete",
                "cancelLabel": "Cancel"
            ]
        ])

        let window = mount(button: button, onAction: { actionsReceived.append($0) })
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated)

        guard let alert = presentedAlert(in: window) else {
            Issue.record("Expected alert controller to be presented")
            return
        }

        guard let confirmAction = alert.actions.first(where: { $0.title == "Delete" }) else {
            Issue.record("Expected 'Delete' confirm action in alert")
            return
        }

        #expect(confirmAction.style == .destructive)
        triggerAlertAction(confirmAction)
        ComponentTestHost.drainRunLoop(for: 0.1)

        #expect(actionsReceived.count == 1)
        #expect(actionsReceived.first?.elementId == "cta_secondary")
        #expect(actionsReceived.first?.isPrimary == false)
        #expect(actionsReceived.first?.label == "Delete Account")
        #expect(actionsReceived.first?.actions == [.dismiss])
    }

    @Test("destructive alert cancel button emits nothing")
    func destructiveAlertCancelEmitsNothing() throws {
        var actionsReceived: [CampaignCanvasActionRequest] = []
        let button = try parsedButton([
            "label": ["spans": [["text": "Delete Account"]]],
            "isDestructive": true,
            "onClick": ["steps": [["type": "Action.dismiss"]]],
            "confirm": [
                "title": "Delete?",
                "message": "Are you sure?",
                "confirmLabel": "Delete",
                "cancelLabel": "Cancel"
            ]
        ])

        let window = mount(button: button, onAction: { actionsReceived.append($0) })
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated)

        guard let alert = presentedAlert(in: window) else {
            Issue.record("Expected alert controller to be presented")
            return
        }

        guard let cancelAction = alert.actions.first(where: { $0.title == "Cancel" }) else {
            Issue.record("Expected 'Cancel' action in alert")
            return
        }

        #expect(cancelAction.style == .cancel)
        triggerAlertAction(cancelAction)
        ComponentTestHost.drainRunLoop(for: 0.1)

        #expect(actionsReceived.isEmpty)
    }

    // MARK: - Interactive Action Helpers

    @discardableResult
    private func activateButton(in window: UIWindow) -> Bool {
        guard let rootView = window.rootViewController?.view,
              let buttonNode = findButtonAccessibilityNode(in: rootView) else {
            return false
        }
        let activated = buttonNode.accessibilityActivate()
        ComponentTestHost.drainRunLoop(for: 0.1)
        return activated
    }

    private func findButtonAccessibilityNode(in root: Any) -> NSObject? {
        if let object = root as? NSObject {
            let traits = object.accessibilityTraits.rawValue
            if (traits & UIAccessibilityTraits.button.rawValue) != 0 {
                return object
            }
        }
        if let view = root as? UIView {
            if let elements = view.accessibilityElements {
                for element in elements {
                    if let found = findButtonAccessibilityNode(in: element) {
                        return found
                    }
                }
            }
            for subview in view.subviews {
                if let found = findButtonAccessibilityNode(in: subview) {
                    return found
                }
            }
        }
        let mirror = Mirror(reflecting: root)
        for child in mirror.children {
            if child.label == "children", let childArray = child.value as? [NSObject] {
                for sub in childArray {
                    if let found = findButtonAccessibilityNode(in: sub) {
                        return found
                    }
                }
            }
        }
        return nil
    }

    private func presentedAlert(in window: UIWindow) -> UIAlertController? {
        ComponentTestHost.drainRunLoop(for: 0.2)
        return window.rootViewController?.presentedViewController as? UIAlertController
    }

    private func triggerAlertAction(_ action: UIAlertAction) {
        guard let handler = action.value(forKey: "handler") else { return }
        typealias AlertHandler = @convention(block) (UIAlertAction) -> Void
        let block = unsafeBitCast(handler as AnyObject, to: AlertHandler.self)
        block(action)
    }


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
        return mount(canvas: canvas, isDark: isDark, onAction: onAction)
    }

    private func mount(
        canvas: CampaignCanvas,
        isDark: Bool = false,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void = { _ in }
    ) -> UIWindow {
        ComponentTestHost.mountCanvas(canvas, isDark: isDark, onAction: onAction).window
    }

    private func unmount(_ window: UIWindow) {
        ComponentTestHost.unmount(window)
    }
}
