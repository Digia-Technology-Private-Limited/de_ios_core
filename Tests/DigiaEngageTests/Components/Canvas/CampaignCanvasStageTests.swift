import Foundation
import Testing
import UIKit
import SwiftUI
@testable import DigiaEngage

@MainActor
@Suite("Campaign canvas stage dispatch", .serialized, .tags(.canvas, .component))
struct CampaignCanvasStageTests {

    @Test("stage dispatches button action to host callback")
    func stageDispatchesButtonAction() throws {
        var dispatchedRequests: [CampaignCanvasActionRequest] = []
        let canvas = try makeCanvasWithButton(
            id: "cta_btn",
            label: "Click Me",
            actions: [EngageAction.openUrl("https://example.com/stage")],
            isPrimary: false
        )

        let (window, _) = ComponentTestHost.mountCanvas(canvas) { request in
            dispatchedRequests.append(request)
        }
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated)
        #expect(dispatchedRequests.count == 1)
        #expect(dispatchedRequests.first?.elementId == "cta_secondary")
        #expect(dispatchedRequests.first?.label == "Click Me")
        #expect(dispatchedRequests.first?.isPrimary == false)
        #expect(dispatchedRequests.first?.actions == [EngageAction.openUrl("https://example.com/stage")])
    }

    @Test("stage dispatches primary flag correctly")
    func stageDispatchesPrimaryFlag() throws {
        var dispatchedRequests: [CampaignCanvasActionRequest] = []
        let canvas = try makeCanvasWithButton(
            id: "primary_btn",
            label: "Primary CTA",
            actions: [EngageAction.dismiss],
            isPrimary: true
        )

        let (window, _) = ComponentTestHost.mountCanvas(canvas) { request in
            dispatchedRequests.append(request)
        }
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        activateButton(in: window)
        #expect(dispatchedRequests.first?.isPrimary == true)
    }

    @Test("stage forwards multiple actions preserving order")
    func stageForwardsMultipleActionsInOrder() throws {
        var dispatchedRequests: [CampaignCanvasActionRequest] = []
        let expectedActions: [EngageAction] = [
            .openUrl("https://example.com/first"),
            .openDeeplink("app://second")
        ]
        let canvas = try makeCanvasWithButton(
            id: "multi_btn",
            label: "Multi",
            actions: expectedActions,
            isPrimary: false
        )

        let (window, _) = ComponentTestHost.mountCanvas(canvas) { request in
            dispatchedRequests.append(request)
        }
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        activateButton(in: window)
        #expect(dispatchedRequests.first?.actions == expectedActions)
    }

    @Test("stage showStory action presents full screen cover when story widget exists")
    func stageShowStoryPresentsCover() throws {
        var dispatchedRequests: [CampaignCanvasActionRequest] = []
        let canvas = try makeCanvasWithStoryAndButton(targetStoryIndex: 0)

        let (window, _) = ComponentTestHost.mountCanvas(canvas) { request in
            dispatchedRequests.append(request)
        }
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        #expect(window.rootViewController?.presentedViewController == nil)

        activateButton(in: window)
        #expect(dispatchedRequests.count == 1)

        ComponentTestHost.drainRunLoop(for: 0.4)
        #expect(window.rootViewController?.presentedViewController != nil)
    }

    @Test("stage showStory without story widget forwards action but does not present cover")
    func stageShowStoryWithoutStoryWidgetDoesNotPresentCover() throws {
        var dispatchedRequests: [CampaignCanvasActionRequest] = []
        let canvas = try makeCanvasWithButton(
            id: "orphan_story_btn",
            label: "Show Story",
            actions: [.showStory(0)],
            isPrimary: false
        )

        let (window, _) = ComponentTestHost.mountCanvas(canvas) { request in
            dispatchedRequests.append(request)
        }
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        activateButton(in: window)
        ComponentTestHost.drainRunLoop(for: 0.2)

        #expect(dispatchedRequests.count == 1)
        #expect(window.rootViewController?.presentedViewController == nil)
    }

    // MARK: - Helpers

    private func makeCanvasWithButton(
        id: String,
        label: String,
        actions: [EngageAction],
        isPrimary: Bool
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

    private func makeCanvasWithStoryAndButton(targetStoryIndex: Int) throws -> CampaignCanvas {
        let storyPage: [String: Any] = [
            "thumbnailType": "image",
            "thumbnailUrl": "https://example.com/page.jpg",
            "durationSeconds": 5.0,
            "canvas": [
                "version": 2,
                "canvasWidth": 360,
                "canvasHeight": 640,
                "children": []
            ]
        ]
        let chromeCanvas: [String: Any] = [
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 60,
            "children": []
        ]

        return try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 300,
            "children": [
                [
                    "kind": "widget",
                    "id": "story_rail",
                    "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 0.5],
                    "widget": [
                        "type": "digia/canvasStory",
                        "props": [
                            "pages": [storyPage],
                            "chromeCanvas": chromeCanvas
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "trigger_story_btn",
                    "rect": ["x": 0.1, "y": 0.6, "width": 0.8, "height": 0.3],
                    "widget": [
                        "type": "digia/button",
                        "props": [
                            "label": [
                                "spans": [
                                    ["text": "Open Story", "color": "#FFFFFFFF", "fontSize": 14]
                                ]
                            ],
                            "style": [
                                "variant": "fill",
                                "fill": ["type": "solid", "color": "#FF2563EB"]
                            ],
                            "isPrimary": false,
                            "onClick": [
                                "steps": [
                                    ["type": "Action.showStory", "data": ["index": targetStoryIndex]]
                                ]
                            ]
                        ]
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
