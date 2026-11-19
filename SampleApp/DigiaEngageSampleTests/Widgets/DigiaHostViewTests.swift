import Testing
import SwiftUI
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// `DigiaHostView`, the UIKit host, and `DigiaHostViewController`, the container that adds it. The app
/// here is plain UIKit with no SwiftUI of its own: `DigiaHostViewController` as the window's root,
/// holding a navigation controller, as the documentation tells a customer to do. Every touch is a
/// real one through the window.
///
/// The dialog is centred, so the app's button sits in the top-left corner where the dialog does not
/// cover it: whether a tap reaches it is then decided by the host alone.
@Suite("DigiaHostView", .serialized, .tags(.integration))
@MainActor
struct DigiaHostViewTests {

    private final class AppScreen: UIViewController {
        let button = UIButton(type: .system)
        private(set) var taps = 0

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .white
            button.setTitle("App button", for: .normal)
            button.frame = CGRect(x: 20, y: 120, width: 120, height: 44)
            button.addAction(UIAction { [weak self] _ in self?.taps += 1 }, for: .touchUpInside)
            view.addSubview(button)
        }
    }

    private func makeWindow(root: UIViewController, _ sdk: SdkHarness) -> UIWindow {
        let window = ComponentTestHost.makeWindow(frame: CGRect(origin: .zero, size: SdkHarness.screen))
        window.rootViewController = root
        window.makeKeyAndVisible()
        sdk.window = window
        return window
    }

    /// The documented shape: `DigiaHostViewController` as the window's root, holding the navigation controller.
    private func mountUIKitApp(_ sdk: SdkHarness) -> AppScreen {
        let screen = AppScreen()
        _ = makeWindow(root: DigiaHostViewController(content: UINavigationController(rootViewController: screen)), sdk)
        ComponentTestHost.drainRunLoop(for: 0.3)
        return screen
    }

    private func tapButton(_ screen: AppScreen, in window: UIWindow) throws {
        let center = screen.button.convert(
            CGPoint(x: screen.button.bounds.midX, y: screen.button.bounds.midY), to: window)
        try TouchSynthesizer.tap(at: center, in: window)
    }

    // Fails if: `DigiaHostView.hitTest` stops returning nil for a hit on the bare hosting view (the
    // `hit !== hostedView` guard), since the host would then take every tap meant for the app.
    @Test("a tap on the app's own button reaches it while no campaign is showing")
    func idleHostLetsTouchesThrough() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let screen = mountUIKitApp(sdk)

        try tapButton(screen, in: sdk.window)

        #expect(screen.taps == 1)
    }

    private struct Overlay {
        let fixture: String
        let key: String
        let shownText: String
    }

    private func expectOverlayClaimsTouches(_ overlay: Overlay) async throws {
        let sdk = try await SdkHarness.start(loadCampaign(overlay.fixture))
        defer { sdk.tearDown() }
        let screen = mountUIKitApp(sdk)
        try sdk.deliver(overlay.key)
        try await sdk.waitUntil("the overlay is on screen") { sdk.isShowing(overlay.shownText) }

        try tapButton(screen, in: sdk.window)

        #expect(screen.taps == 0)
    }

    // Fails if: `DigiaHostView.hitTest` stops returning SwiftUI's own hit for what it is drawing (its
    // last line), since the host would then let every tap through to the button under the dialog.
    @Test("a tap on the app's own button is claimed by the host while a dialog is showing")
    func dialogClaimsTouches() async throws {
        try await expectOverlayClaimsTouches(Overlay(
            fixture: "campaigns/nudge_dialog/nudge_dialog.json",
            key: "test_nudge_dialog", shownText: "Dialog Test Nudge"))
    }

    @Test("a tap on the app's own button is claimed by the host while a survey is showing")
    func surveyClaimsTouches() async throws {
        try await expectOverlayClaimsTouches(Overlay(
            fixture: "campaigns/survey/survey_stacked_cta.json",
            key: "test_survey_stacked_cta", shownText: "Option Alpha"))
    }

    // Fails if: `SDKInstance.route` stops calling `DigiaHostAttachment.ensure()` (the second dialog
    // would have no host in the window, so it never draws), or `ensure()` stops ending what the
    // swapped-out root was showing (`endCampaignsForHostTeardown`; the first dialog would stay
    // "displaying", holding the CEP's slot).
    @Test("after the app replaces its root, the next campaign ends the one left on screen and draws over the new root")
    func rootSwapIsHandledWhenTheNextCampaignArrives() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let window = makeWindow(root: AppScreen(), sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        let first = try sdk.deliver("test_nudge_dialog")
        try await sdk.waitUntil("the first dialog is on screen") { sdk.isShowing("Dialog Test Nudge") }

        let newRoot = AppScreen()
        window.rootViewController = newRoot
        try await sdk.settle(0.3)
        #expect(sdk.outcome(of: first) == nil)  // nothing notices the swap until a campaign is routed

        let second = try sdk.deliver("test_nudge_dialog")

        #expect(sdk.outcome(of: first) == .dismissed(reason: .cancelled, completed: false))
        #expect(!sdk.records("test_nudge_dialog", reason: TimelineReason.hostTeardown).isEmpty)
        try await sdk.waitUntil("the second dialog is on screen over the new root") {
            second.state == .displaying && sdk.isShowing("Dialog Test Nudge")
        }
        #expect(newRoot.view.subviews.last is DigiaHostView)
    }

    private final class PortraitScreen: UIViewController {
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
        override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    }

    // Fails if: `DigiaHostViewController` stops passing `supportedInterfaceOrientations` to its content. UIKit asks
    // only the window's root, so the app's portrait lock would be lost and its screens would rotate.
    @Test("the app's own orientation lock and status bar style reach UIKit through the container")
    func containerPassesSystemChoicesThrough() {
        let container = DigiaHostViewController(content: PortraitScreen())

        #expect(container.supportedInterfaceOrientations == .portrait)
        #expect(container.childForStatusBarStyle?.preferredStatusBarStyle == .lightContent)
    }

    // Fails if: `owningViewController` stops climbing past navigation and tab bar controllers. The host
    // would then add its hosting controller to one as a child, which UIKit treats as a screen of its
    // own: the navigation stack gains a blank top screen, the tab bar a blank tab. Mounted for real,
    // that regression freezes the app, so the choice of controller is tested, not the mount.
    @Test("a host's owning controller is never a navigation or tab bar controller")
    func owningControllerSkipsContainers() {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let inNavigation = UIView()
        navigation.view.addSubview(inNavigation)
        #expect(inNavigation.owningViewController == nil)

        let tabs = UITabBarController()
        tabs.viewControllers = [UIViewController()]
        let inTabs = UIView()
        tabs.view.addSubview(inTabs)
        #expect(inTabs.owningViewController == nil)

        // A navigation controller inside a plain one: the plain one is what the host can use.
        let root = UIViewController()
        let embedded = UINavigationController(rootViewController: UIViewController())
        root.addChild(embedded)
        root.view.addSubview(embedded.view)
        embedded.didMove(toParent: root)
        let inEmbedded = UIView()
        embedded.view.addSubview(inEmbedded)
        #expect(inEmbedded.owningViewController === root)

        let screen = UIViewController()
        let onScreen = UIView()
        screen.view.addSubview(onScreen)
        #expect(onScreen.owningViewController === screen)
    }

    // Fails if: `owningViewController` falls back to the window's root controller for a view added straight to a
    // window. The host would then add its hosting controller as a child of that root, and UIKit throws, because the
    // host's view is in the window and not in the root's view. That crashes the host app.
    @Test("a host added straight to a window has no owning controller, however plain the window's root is")
    func owningControllerIsNilForAViewAddedToAWindow() {
        let window = ComponentTestHost.makeWindow(frame: CGRect(origin: .zero, size: SdkHarness.screen))
        defer { ComponentTestHost.cleanupOverlayWindow(window) }
        window.rootViewController = UIViewController()
        let onWindow = UIView()
        window.addSubview(onWindow)

        #expect(onWindow.owningViewController == nil)
    }
}
}
