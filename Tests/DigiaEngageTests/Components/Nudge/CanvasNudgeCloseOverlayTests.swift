import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@Suite("Canvas nudge close overlay", .serialized, .tags(.nudge, .unit))
struct CanvasNudgeCloseOverlayTests {

    @Test("outside top placement executes action on button tap") @MainActor
    func testOutsideTopPlacementTapExecutesAction() {
        var actionExecuted = false
        let placement = NudgeCloseButtonPlacement(
            horizontal: .right,
            vertical: .top,
            margin: .init(top: 8, right: 12, bottom: 8, left: 12)
        )
        let config = NudgeCloseButtonConfig(
            marginTop: 8,
            marginRight: 12,
            backgroundColor: .clear,
            iconColor: .black,
            iconSize: 16,
            placement: placement
        )
        let overlay = CanvasNudgeCloseOverlay(
            config: config,
            container: CGRect(x: 20, y: 60, width: 320, height: 200),
            viewport: CGSize(width: 360, height: 400),
            safeAreaInsets: .zero,
            isBottomSheet: false,
            action: { actionExecuted = true }
        )

        let (window, _) = ComponentTestHost.mount(
            rootView: overlay,
            size: CGSize(width: 360, height: 400)
        )
        defer { ComponentTestHost.unmount(window) }

        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated == true)
        #expect(actionExecuted == true)
    }

    @Test("outside bottom placement executes action on button tap") @MainActor
    func testOutsideBottomPlacementTapExecutesAction() {
        var actionExecuted = false
        let placement = NudgeCloseButtonPlacement(
            horizontal: .left,
            vertical: .bottom,
            margin: .init(top: 10, right: 10, bottom: 10, left: 10)
        )
        let config = NudgeCloseButtonConfig(
            marginTop: 0,
            marginRight: 0,
            backgroundColor: .clear,
            iconColor: .black,
            iconSize: 16,
            placement: placement
        )
        let overlay = CanvasNudgeCloseOverlay(
            config: config,
            container: CGRect(x: 20, y: 60, width: 320, height: 200),
            viewport: CGSize(width: 360, height: 400),
            safeAreaInsets: .zero,
            isBottomSheet: false,
            action: { actionExecuted = true }
        )

        let (window, _) = ComponentTestHost.mount(
            rootView: overlay,
            size: CGSize(width: 360, height: 400)
        )
        defer { ComponentTestHost.unmount(window) }

        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated == true)
        #expect(actionExecuted == true)
    }

    @Test("inside placement resolves within container and executes action") @MainActor
    func testInsidePlacementTapExecutesAction() {
        var actionExecuted = false
        let placement = NudgeCloseButtonPlacement(
            horizontal: .right,
            vertical: .top,
            margin: .init(),
            rect: CGRect(x: 0.85, y: 0.05, width: 0.1, height: 0.1)
        )
        let config = NudgeCloseButtonConfig(
            marginTop: 0,
            marginRight: 0,
            backgroundColor: .clear,
            iconColor: .black,
            iconSize: 16,
            placement: placement
        )
        let overlay = CanvasNudgeCloseOverlay(
            config: config,
            container: CGRect(x: 20, y: 60, width: 320, height: 200),
            viewport: CGSize(width: 360, height: 400),
            safeAreaInsets: .zero,
            isBottomSheet: false,
            action: { actionExecuted = true }
        )

        let (window, _) = ComponentTestHost.mount(
            rootView: overlay,
            size: CGSize(width: 360, height: 400)
        )
        defer { ComponentTestHost.unmount(window) }

        ComponentTestHost.drainRunLoop(for: 0.1)

        let activated = activateButton(in: window)
        #expect(activated == true)
        #expect(actionExecuted == true)
    }

    @Test("custom accessibilityLabel propagates to close button element") @MainActor
    func testCustomAccessibilityLabelPropagates() {
        let placement = NudgeCloseButtonPlacement(
            horizontal: .right,
            vertical: .top,
            margin: .init(top: 8, right: 8, bottom: 8, left: 8)
        )
        let config = NudgeCloseButtonConfig(
            marginTop: 0,
            marginRight: 0,
            backgroundColor: .clear,
            iconColor: .black,
            iconSize: 16,
            placement: placement
        )
        let overlay = CanvasNudgeCloseOverlay(
            config: config,
            container: CGRect(x: 20, y: 60, width: 320, height: 200),
            viewport: CGSize(width: 360, height: 400),
            safeAreaInsets: .zero,
            isBottomSheet: false,
            action: {},
            accessibilityLabel: "Dismiss promo"
        )

        let (window, _) = ComponentTestHost.mount(
            rootView: overlay,
            size: CGSize(width: 360, height: 400)
        )
        defer { ComponentTestHost.unmount(window) }

        ComponentTestHost.drainRunLoop(for: 0.1)

        guard let rootView = window.rootViewController?.view,
              let buttonNode = findButtonAccessibilityNode(in: rootView) else {
            Issue.record("Button accessibility node not found")
            return
        }
        #expect(buttonNode.accessibilityLabel == "Dismiss promo")
    }

    // MARK: - Helpers

    @MainActor
    private func activateButton(in window: UIWindow) -> Bool {
        guard let rootView = window.rootViewController?.view,
              let buttonNode = findButtonAccessibilityNode(in: rootView) else {
            return false
        }
        let activated = buttonNode.accessibilityActivate()
        ComponentTestHost.drainRunLoop(for: 0.1)
        return activated
    }

    @MainActor
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
