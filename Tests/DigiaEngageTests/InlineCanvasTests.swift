import Foundation
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Inline canvas", .serialized, .tags(.canvas, .inline, .contract))
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

/// One slot holds one campaign, whatever kind it is.
///
/// `DigiaSlot` resolves the kinds in a fixed order with carousel first, so a
/// config left behind by a previous campaign in the same slot silently wins.
@MainActor
@Suite("Inline slot config exclusivity", .serialized, .tags(.canvas, .inline, .unit))
struct InlineSlotConfigExclusivityTests {
    private let slot = "home_rail"

    @Test("a story replaces a carousel in the same slot")
    func storyReplacesCarousel() {
        let controller = InlineCampaignController()
        controller.setCarouselConfig(slot, config: InlineCarouselConfig(slotKey: slot, items: []))
        controller.setStoryConfig(slot, config: InlineStoryConfig(slotKey: slot, items: []))

        #expect(controller.getCarouselConfig(slot) == nil)
        #expect(controller.getStoryConfig(slot) != nil)
    }

    @Test("a carousel replaces a story in the same slot")
    func carouselReplacesStory() {
        let controller = InlineCampaignController()
        controller.setStoryConfig(slot, config: InlineStoryConfig(slotKey: slot, items: []))
        controller.setCarouselConfig(slot, config: InlineCarouselConfig(slotKey: slot, items: []))

        #expect(controller.getStoryConfig(slot) == nil)
        #expect(controller.getCarouselConfig(slot) != nil)
    }
}

@MainActor
@Suite("Inline canvas perform action routing", .serialized, .tags(.canvas, .inline, .component))
struct InlineCanvasPerformTests {

    @Test("perform routes open_url action to registered handler when slot payload matches")
    func performRoutesOpenUrlActionOnMatchingPayload() async throws {
        defer { SDKInstance.shared.resetForTesting() }

        var openedUrl: String?
        SDKInstance.shared.setOpenURLHandler { url in
            openedUrl = url
        }

        let canvas = try makeCanvasWithButton(
            id: "url_btn",
            actions: [.openUrl("https://digia.com")]
        )
        let config = makeInlineConfig(slotKey: "home_hero", canvas: canvas)
        let payload = CEPTriggerPayload(
            cepCampaignId: "cep-1",
            campaignKey: "key-1",
            cepMetadata: [:]
        )
        SDKInstance.shared.inlineController.setCampaign("home_hero", payload: payload)

        let (window, _) = ComponentTestHost.mount(
            rootView: DigiaInlineCanvasView(config: config, payload: payload),
            size: CGSize(width: 360, height: 120)
        )
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated)

        for _ in 0..<15 {
            if openedUrl != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            ComponentTestHost.drainRunLoop(for: 0.05)
        }

        #expect(openedUrl == "https://digia.com")
    }

    @Test("perform with hideInline dismiss action clears the campaign from slot controller")
    func performDismissClearsActiveCampaign() async throws {
        defer { SDKInstance.shared.resetForTesting() }

        let canvas = try makeCanvasWithButton(
            id: "dismiss_btn",
            actions: [.dismiss]
        )
        let config = makeInlineConfig(slotKey: "home_hero", canvas: canvas)
        let payload = CEPTriggerPayload(
            cepCampaignId: "cep-dismiss",
            campaignKey: "key-dismiss",
            cepMetadata: [:]
        )
        SDKInstance.shared.inlineController.setCampaign("home_hero", payload: payload)
        #expect(SDKInstance.shared.inlineController.getCampaign("home_hero") == payload)

        let (window, _) = ComponentTestHost.mount(
            rootView: DigiaInlineCanvasView(config: config, payload: payload),
            size: CGSize(width: 360, height: 120)
        )
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated)

        for _ in 0..<15 {
            if SDKInstance.shared.inlineController.getCampaign("home_hero") == nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            ComponentTestHost.drainRunLoop(for: 0.05)
        }

        #expect(SDKInstance.shared.inlineController.getCampaign("home_hero") == nil)
    }

    @Test("perform aborts action execution when slot holds a different campaign payload")
    func performAbortsOnMismatchedPayload() async throws {
        defer { SDKInstance.shared.resetForTesting() }

        var openedUrl: String?
        SDKInstance.shared.setOpenURLHandler { url in
            openedUrl = url
        }

        let canvas = try makeCanvasWithButton(
            id: "mismatch_btn",
            actions: [.openUrl("https://digia.com")]
        )
        let config = makeInlineConfig(slotKey: "home_hero", canvas: canvas)
        let renderedPayload = CEPTriggerPayload(
            cepCampaignId: "cep-rendered",
            campaignKey: "key-rendered",
            cepMetadata: [:]
        )
        let currentPayload = CEPTriggerPayload(
            cepCampaignId: "cep-current",
            campaignKey: "key-current",
            cepMetadata: [:]
        )
        SDKInstance.shared.inlineController.setCampaign("home_hero", payload: currentPayload)

        let (window, _) = ComponentTestHost.mount(
            rootView: DigiaInlineCanvasView(config: config, payload: renderedPayload),
            size: CGSize(width: 360, height: 120)
        )
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated)

        try? await Task.sleep(nanoseconds: 60_000_000)
        ComponentTestHost.drainRunLoop(for: 0.1)

        #expect(openedUrl == nil)
        #expect(SDKInstance.shared.inlineController.getCampaign("home_hero") == currentPayload)
    }

    @Test("perform interpolates campaign variables into deep link action before routing")
    func performResolvesVariablesInDeepLink() async throws {
        defer { SDKInstance.shared.resetForTesting() }

        var handledDeeplink: String?
        SDKInstance.shared.setDeepLinkHandler { link in
            handledDeeplink = link
        }

        let canvas = try makeCanvasWithButton(
            id: "deeplink_btn",
            actions: [.openDeeplink("myapp://promo/{{promo_code}}")]
        )
        let config = makeInlineConfig(
            slotKey: "home_hero",
            canvas: canvas,
            variableSchemas: [
                VariableSchema(name: "promo_code", type: "string", fallbackValue: "FALLBACK10")
            ]
        )
        let payload = CEPTriggerPayload(
            cepCampaignId: "cep-var",
            campaignKey: "key-var",
            cepMetadata: [:],
            variables: ["promo_code": "SAVE50"]
        )
        SDKInstance.shared.inlineController.setCampaign("home_hero", payload: payload)

        let (window, _) = ComponentTestHost.mount(
            rootView: DigiaInlineCanvasView(config: config, payload: payload),
            size: CGSize(width: 360, height: 120)
        )
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated)

        for _ in 0..<15 {
            if handledDeeplink != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            ComponentTestHost.drainRunLoop(for: 0.05)
        }

        #expect(handledDeeplink == "myapp://promo/SAVE50")
    }

    @Test("perform ignores button with empty actions and does not dispatch to handlers")
    func performWithEmptyActionsDoesNotTriggerHandler() async throws {
        defer { SDKInstance.shared.resetForTesting() }

        var actionHandled = false
        SDKInstance.shared.setOpenURLHandler { _ in
            actionHandled = true
        }
        SDKInstance.shared.setDeepLinkHandler { _ in
            actionHandled = true
        }

        let canvas = try makeCanvasWithButton(
            id: "empty_btn",
            actions: []
        )
        let config = makeInlineConfig(slotKey: "home_hero", canvas: canvas)
        let payload = CEPTriggerPayload(
            cepCampaignId: "cep-empty",
            campaignKey: "key-empty",
            cepMetadata: [:]
        )
        SDKInstance.shared.inlineController.setCampaign("home_hero", payload: payload)

        let (window, _) = ComponentTestHost.mount(
            rootView: DigiaInlineCanvasView(config: config, payload: payload),
            size: CGSize(width: 360, height: 120)
        )
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(!activated)

        try? await Task.sleep(nanoseconds: 60_000_000)
        ComponentTestHost.drainRunLoop(for: 0.1)

        #expect(!actionHandled)
        #expect(SDKInstance.shared.inlineController.getCampaign("home_hero") == payload)
    }

    // MARK: - Helpers

    private func makeInlineConfig(
        slotKey: String = "home_hero",
        canvas: CampaignCanvas,
        variableSchemas: [VariableSchema] = []
    ) -> InlineCanvasConfig {
        var config = InlineCanvasConfig(
            slotKey: slotKey,
            designWidth: Double(canvas.width),
            cornerRadius: 12,
            margin: .init(),
            canvas: canvas
        )
        config.variableSchemas = variableSchemas
        return config
    }

    private func makeCanvasWithButton(
        id: String = "test_btn",
        label: String = "Click Me",
        actions: [EngageAction],
        isPrimary: Bool = false
    ) throws -> CampaignCanvas {
        let actionSteps: [[String: Any]] = actions.compactMap { action in
            switch action {
            case .openUrl(let url):
                return ["type": "open_url", "data": ["url": url]]
            case .openDeeplink(let link):
                return ["type": "deep_link", "data": ["url": link]]
            case .dismiss:
                return ["type": "Action.hideInline"]
            case .showStory(let index):
                return ["type": "Action.showStory", "data": ["index": index]]
            default:
                return nil
            }
        }

        let buttonProps: [String: Any] = [
            "label": [
                "spans": [
                    ["text": label, "color": "#FFFFFFFF", "fontSize": 14, "fontWeight": 600]
                ]
            ],
            "style": [
                "variant": "fill",
                "fill": ["type": "solid", "color": "#FF2563EB"]
            ],
            "cornerRadius": 8,
            "isPrimary": isPrimary,
            "onClick": ["steps": actionSteps]
        ]

        return try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 120,
            "children": [
                [
                    "kind": "widget",
                    "id": id,
                    "rect": ["x": 0.05, "y": 0.1, "width": 0.9, "height": 0.8],
                    "widget": [
                        "type": "digia/button",
                        "props": buttonProps
                    ]
                ]
            ]
        ])
    }

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
}

