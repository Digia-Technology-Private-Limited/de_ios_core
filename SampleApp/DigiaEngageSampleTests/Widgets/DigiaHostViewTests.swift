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

    // Fails if: `DigiaHostView.didMoveToWindow` stops telling `DigiaHostAttachment` the host left the
    // window, or `ensure()` stops ending what the swapped-out root was showing (`endCampaignsForHostTeardown`):
    // the first dialog would stay "displaying" off screen, holding the CEP's slot and its dwell timer.
    @Test("when the app replaces its root, the campaign left on screen ends at once and the host moves to the new root")
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
        try await sdk.waitUntil("the dialog left with the old root is ended") { sdk.outcome(of: first) != nil }

        #expect(sdk.outcome(of: first) == .dismissed(reason: .cancelled, completed: false))
        #expect(!sdk.records("test_nudge_dialog", reason: TimelineReason.hostTeardown).isEmpty)
        #expect(newRoot.view.subviews.last is DigiaHostView)

        let second = try sdk.deliver("test_nudge_dialog")
        try await sdk.waitUntil("the second dialog is on screen over the new root") {
            second.state == .displaying && sdk.isShowing("Dialog Test Nudge")
        }
        #expect(newRoot.view.subviews.last is DigiaHostView)
    }

    // Fails if: the nudge cover's binding setter (`NudgeOverlayView.coverBinding`) reports anything but cancelled
    // when the system tears the cover down: a root swap would end the sheet as user_close, counting a close the
    // user never made.
    @Test("when the app replaces its root under a bottom sheet, the sheet ends as cancelled, not user_close")
    func rootSwapUnderASheetIsNotAUserClose() async throws {
        let sdk = try await SdkHarness.start(
            loadCampaign("campaigns/nudge_bottomsheet/nudge_bottomsheet_backdrop_on.json"))
        defer { sdk.tearDown() }
        let window = makeWindow(root: AppScreen(), sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        let sheet = try sdk.deliver("test_nudge_bottomsheet_backdrop_on")
        try await sdk.waitUntil("the sheet is on screen") { sdk.isShowing("Backdrop Tap Dismiss On") }

        window.rootViewController = AppScreen()
        try await sdk.waitUntil("the sheet left with the old root is ended") { sdk.outcome(of: sheet) != nil }

        #expect(sdk.outcome(of: sheet) == .dismissed(reason: .cancelled, completed: false))
    }

    // Fails if: `endCampaignsForHostTeardown` stops ending a survey through `SurveySurface.end`
    // (`markSurveyDismissed`), e.g. back to cancelling its presentation: the survey would leave with no Digia
    // Dismissed, leaving its Viewed orphaned.
    @Test("when the app replaces its root under a survey, the survey ends cancelled with Digia's dismissal")
    func rootSwapEndsASurveyWithItsDismissal() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/survey/survey_stacked_cta.json"))
        defer { sdk.tearDown() }
        let window = makeWindow(root: AppScreen(), sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        let survey = try sdk.deliver("test_survey_stacked_cta")
        try await sdk.waitUntil("the survey is on screen") { sdk.isShowing("Option Alpha") }

        window.rootViewController = AppScreen()
        try await sdk.waitUntil("the survey left with the old root is ended") { sdk.outcome(of: survey) != nil }

        #expect(sdk.outcome(of: survey) == .dismissed(reason: .cancelled, completed: false))
        let dismissals = try await sdk.events().filter {
            $0["campaign_key"] as? String == "test_survey_stacked_cta"
                && $0["event_name"] as? String == "Digia Experience Dismissed"
        }
        #expect(dismissals.count == 1)
        #expect((dismissals.first?["properties"] as? [String: Any])?["dismiss_reason"] as? String == "cancelled")
    }

    // Fails if: `endCampaignsForHostTeardown` goes back to finding what to end by presentation id: a live
    // test has none, so it would stay on screen over the new root and its dashboard row would never hear the end.
    @Test("when the app replaces its root under a live test, the test ends and its dashboard row hears cancelled")
    func rootSwapEndsALiveTest() async throws {
        let campaign = try loadCampaign("campaigns/nudge_dialog/nudge_dialog.json")
        let sdk = try await SdkHarness.start(campaigns: [])
        defer { sdk.tearDown() }
        sdk.sdk.liveTestService.ackReporter.configure(config: DigiaConfig(apiKey: "test-api-key"))
        let window = makeWindow(root: AppScreen(), sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        sdk.sdk.handleLiveTestCampaign(LiveTestInvocation(
            testInvocationId: "inv-1", campaignId: campaign["id"] as? String ?? "live", campaign: campaign,
            variables: [:]))
        try await sdk.waitUntil("the live test is on screen") { sdk.isShowing("Dialog Test Nudge") }

        window.rootViewController = AppScreen()
        try await sdk.waitUntil("the live test leaves the controller") { sdk.sdk.controller.activeNudge == nil }

        try await sdk.waitUntil("the dismissal reaches the dashboard") {
            sdk.network.recordedRequests.contains { $0.url.absoluteString == DigiaEndpoints.liveTestEvent }
        }
        let event = sdk.network.recordedRequests
            .last { $0.url.absoluteString == DigiaEndpoints.liveTestEvent }
            .flatMap { $0.body }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(event?["type"] as? String == "dismissed")
        #expect((event?["payload"] as? [String: Any])?["reason"] as? String == "cancelled")
    }

    // Fails if: `SDKInstance.onHostUnmounted` stops ending what the last `DigiaHost` drew when it leaves
    // without attach: the dialog would stay "displaying" off screen, holding the CEP's slot.
    @Test("without attach, replacing the root that holds the DigiaHost ends the campaign at once")
    func swiftUIRootSwapEndsTheCampaign() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        SDKInstance.shared.onHostUnmounted(SDKInstance.testHostId)
        try sdk.mount { Text("App home") }
        let dialog = try sdk.deliver("test_nudge_dialog")
        try await sdk.waitUntil("the dialog is on screen") { sdk.isShowing("Dialog Test Nudge") }

        let window = try #require(ViewControllerUtil.keyWindow())
        window.rootViewController = AppScreen()
        try await sdk.waitUntil("the dialog left with the old root is ended") { sdk.outcome(of: dialog) != nil }

        #expect(sdk.outcome(of: dialog) == .dismissed(reason: .cancelled, completed: false))
    }

    // Fails if: the `appPresentation` guard in `SDKInstance.onHostUnmounted` goes: a full-screen modal of the
    // app's own takes the host out of the window too, and would wrongly end the campaign under it.
    @Test("without attach, the app's full-screen modal over the DigiaHost does not end the campaign")
    func swiftUIAppModalKeepsTheCampaign() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        SDKInstance.shared.onHostUnmounted(SDKInstance.testHostId)
        try sdk.mount { Text("App home") }
        let dialog = try sdk.deliver("test_nudge_dialog")
        try await sdk.waitUntil("the dialog is on screen") { sdk.isShowing("Dialog Test Nudge") }

        let root = try #require(ViewControllerUtil.keyWindow()?.rootViewController)
        let modal = AppScreen()
        modal.modalPresentationStyle = .fullScreen
        root.present(modal, animated: false)
        try await sdk.settle(1.0)

        #expect(sdk.outcome(of: dialog) == nil)
        root.dismiss(animated: false)
        try await sdk.settle(0.5)
    }

    // Fails if: `endCampaignsForHostTeardown` stops ending the floaters (`floaterStoryOrchestrator.dismiss(.hostTeardown)`):
    // the floater left by the swapped-out root would stay "displaying" and the next one would be
    // dropped as surface_busy.
    @Test("after the app replaces its root, a floater left on screen ends and the next floater draws")
    func rootSwapEndsAFloaterLeftOnScreen() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/floater/floater_story_window.json"))
        defer { sdk.tearDown() }
        let window = makeWindow(root: AppScreen(), sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        let first = try sdk.deliver("test_floater_story")
        try await sdk.waitUntil("the first floater is on screen") { first.state == .displaying }

        window.rootViewController = AppScreen()
        try await sdk.settle(0.3)
        let second = try sdk.deliver("test_floater_story")

        #expect(sdk.outcome(of: first) == .dismissed(reason: .cancelled, completed: false))
        #expect(!sdk.records("test_floater_story", reason: TimelineReason.hostTeardown).isEmpty)
        try await sdk.waitUntil("the second floater is on screen over the new root") {
            second.state == .displaying
        }
    }

    // Fails if: `DigiaHost` stops gating its overlays on `HostRegistry.isActive` (`shownIf(drawsOverlays)`):
    // both hosts would draw the dialog. Or if `HostRegistry.unmount` stops handing over to the host
    // mounted before: nothing would draw once the newer host goes.
    @Test("with attach in use, only the latest host draws a campaign, and the earlier one takes over when it goes")
    func onlyTheLatestHostDraws() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        let attached = try #require(root.view.subviews.last as? DigiaHostView)

        // A SwiftUI screen with its own `DigiaHost`, added after `attach`.
        let screen = UIHostingController(rootView: DigiaHost { Color.clear })
        root.addChild(screen)
        screen.view.frame = root.view.bounds
        screen.view.backgroundColor = .clear
        root.view.insertSubview(screen.view, belowSubview: attached)
        screen.didMove(toParent: root)
        try await sdk.settle(0.3)

        try sdk.deliver("test_nudge_dialog")
        try await sdk.waitUntil("the dialog is on screen") { sdk.isShowing("Dialog Test Nudge") }
        let shows: (UIView) -> Bool = { host in
            SdkHarness.find(in: host) { SdkHarness.shownText(of: $0)?.contains("Dialog Test Nudge") == true } != nil
        }
        #expect(shows(screen.view))
        #expect(!shows(attached))

        screen.willMove(toParent: nil)
        screen.view.removeFromSuperview()
        screen.removeFromParent()
        try await sdk.waitUntil("the attached host draws the dialog") { shows(attached) }
    }

    private func dropReason(_ presentation: CampaignPresentation, _ sdk: SdkHarness) -> DropReason? {
        guard case .dropped(let reason, _)? = sdk.outcome(of: presentation) else { return nil }
        return reason
    }

    // Fails if: the router's host gate stops asking `hostUnavailable`, or that stops answering
    // `host_not_mounted` when `attach` found no root it can use. The dialog would then wait for the
    // 15 s watchdog and end as `timeout`.
    @Test("with attach on a navigation root, a campaign is dropped at once as host_not_mounted")
    func noUsableRootDropsAsHostNotMounted() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        SDKInstance.shared.onHostUnmounted(SDKInstance.testHostId)
        let window = makeWindow(root: UINavigationController(rootViewController: AppScreen()), sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)

        let presentation = try sdk.deliver("test_nudge_dialog")

        #expect(dropReason(presentation, sdk) == .hostNotMounted)
    }

    // Fails if: `hostUnavailable` stops answering `host_not_mounted` without attach when no `DigiaHost`
    // is mounted. The dialog would wait for the 15 s watchdog and end as `timeout`.
    @Test("without attach, a campaign with no DigiaHost mounted is dropped at once as host_not_mounted")
    func noDigiaHostDropsAsHostNotMounted() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        SDKInstance.shared.onHostUnmounted(SDKInstance.testHostId)

        let presentation = try sdk.deliver("test_nudge_dialog")

        #expect(dropReason(presentation, sdk) == .hostNotMounted)
    }

    // Fails if: `hostUnavailable` stops answering `host_modal_open` while the app presents a
    // controller of its own. The dialog would be drawn under the app's modal and count an impression.
    @Test("with attach, a dialog triggered while the app presents its own modal is dropped at once as host_modal_open")
    func appModalDropsAsHostModalOpen() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        root.present(AppScreen(), animated: false)
        ComponentTestHost.drainRunLoop(for: 0.3)

        let blocked = try sdk.deliver("test_nudge_dialog")

        #expect(dropReason(blocked, sdk) == .hostModalOpen)
        try await sdk.settle(0.5)
        #expect(try await sdk.eventNames(of: "test_nudge_dialog").contains("Digia Experience Viewed") == false)

        root.dismiss(animated: false)
        try await sdk.settle(0.5)  // yield: UIKit finishes the dismissal between main-actor jobs
        let shown = try sdk.deliver("test_nudge_dialog")
        try await sdk.waitUntil("the dialog shows once the modal is closed") { shown.state == .displaying }
    }

    // Fails if: `hostUnavailable` stops checking surveys for an app modal (`case .nudge, .survey`): the survey
    // would be drawn under the app's modal and count an impression.
    @Test("with attach, a survey triggered while the app presents its own modal is dropped at once as host_modal_open")
    func appModalDropsASurveyAsHostModalOpen() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/survey/survey_stacked_cta.json"))
        defer { sdk.tearDown() }
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        root.present(AppScreen(), animated: false)
        ComponentTestHost.drainRunLoop(for: 0.3)

        let blocked = try sdk.deliver("test_survey_stacked_cta")

        #expect(dropReason(blocked, sdk) == .hostModalOpen)
        root.dismiss(animated: false)
        try await sdk.settle(0.5)
    }

    // Fails if: `hostUnavailable` stops leaving Digia's own presentations to the surface rule (`digiaPresents`):
    // a bottom sheet on screen is a presented controller too, and the next nudge would be misreported as
    // host_modal_open instead of surface_busy.
    @Test("with attach, Digia's own presented sheet turns the next nudge away as surface_busy, not host_modal_open")
    func ownPresentationIsSurfaceBusy() async throws {
        let sdk = try await SdkHarness.start(campaigns: [
            loadCampaign("campaigns/nudge_bottomsheet/nudge_bottomsheet_backdrop_on.json"),
            loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"),
        ])
        defer { sdk.tearDown() }
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        let sheet = try sdk.deliver("test_nudge_bottomsheet_backdrop_on")
        try await sdk.waitUntil("the sheet is presented") {
            sheet.state == .displaying && root.presentedViewController != nil
        }

        let second = try sdk.deliver("test_nudge_dialog")

        #expect(dropReason(second, sdk) == .surfaceBusy)
    }

    // Fails if: `DigiaHostAttachment.ensure()` stops reusing its one host (`self.host ?? DigiaHostView(...)`):
    // a second attach would add a second host and every campaign would be drawn twice.
    @Test("calling attach twice keeps exactly one host in the root")
    func doubleAttachKeepsOneHost() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(root.view.subviews.filter { $0 is DigiaHostView }.count == 1)
    }

    // Fails if: `attach(to:)` stops switching to the window it is given (`self.window = window`): an app that
    // makes a new window would keep the host in the old one, and campaigns would not draw in the new one.
    @Test("attach to a new window moves the host into the new window's root")
    func attachToANewWindowMovesTheHost() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let firstRoot = AppScreen()
        let first = makeWindow(root: firstRoot, sdk)
        Digia.attach(to: first)
        ComponentTestHost.drainRunLoop(for: 0.3)

        let secondRoot = AppScreen()
        let second = makeWindow(root: secondRoot, sdk)
        Digia.attach(to: second)
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(secondRoot.view.subviews.last is DigiaHostView)
        #expect(!firstRoot.view.subviews.contains { $0 is DigiaHostView })
        let shown = try sdk.deliver("test_nudge_dialog")
        try await sdk.waitUntil("the dialog draws in the new window") { shown.state == .displaying }
        first.isHidden = true
    }

    private func openStory(_ sdk: SdkHarness) -> Bool {
        SDKInstance.shared.controller.showStoryOverlay(
            config: InlineStoryConfig(slotKey: "story_slot", items: []), initialIndex: 0,
            payload: CEPTriggerPayload(cepCampaignId: "cep-story", campaignKey: "story_test", cepMetadata: [:]))
    }

    // Fails if: `endCampaignsForHostTeardown` stops closing an open story: `activeStoryOverlay` would stay set
    // after the root (and the story with it) is gone, `hasActiveOverlay` would stay true, and the host would
    // swallow every touch on the new root.
    @Test("with attach, a story open when the app replaces its root is closed, and the app gets its touches back")
    func rootSwapClosesAnOpenStory() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let window = makeWindow(root: AppScreen(), sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.5)
        #expect(openStory(sdk))

        window.rootViewController = AppScreen()
        try await sdk.waitUntil("the story is closed") { SDKInstance.shared.controller.activeStoryOverlay == nil }

        #expect(!Digia.hasActiveOverlay)
    }

    // Fails if: the story controller stops clearing the story state when UIKit dismisses it from outside the
    // SDK (`DigiaStoryHostingController.viewDidDisappear`): the app would be frozen behind a story that is gone.
    @Test("a story dismissed by the app, not by the SDK, no longer counts as open")
    func externallyDismissedStoryIsClosed() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.5)
        #expect(openStory(sdk))
        try await sdk.waitUntil("the story is presented") { root.presentedViewController != nil }

        root.dismiss(animated: false)
        try await sdk.waitUntil("the story is closed") { SDKInstance.shared.controller.activeStoryOverlay == nil }

        #expect(!Digia.hasActiveOverlay)
    }

    // Fails if: an open story stops counting as Digia's own presentation that turns new nudges away
    // (`hostUnavailable`): the dialog would be drawn hidden behind the story and count an impression.
    @Test("with a story open, a new dialog is turned away as surface_busy")
    func openStoryTurnsANudgeAway() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.5)
        #expect(openStory(sdk))
        try await sdk.waitUntil("the story is presented") { root.presentedViewController != nil }

        let blocked = try sdk.deliver("test_nudge_dialog")

        #expect(dropReason(blocked, sdk) == .surfaceBusy)
        SDKInstance.shared.controller.dismissStoryOverlay()
        try await sdk.settle(0.5)
    }

    private func presentFullScreen(over root: UIViewController) {
        let modal = AppScreen()
        modal.modalPresentationStyle = .fullScreen
        root.present(modal, animated: false)
        ComponentTestHost.drainRunLoop(for: 0.5)
    }

    // Fails if: `DigiaHostAttachment.hasHost` goes back to requiring the host in a window: a full-screen modal
    // takes the root's view out of the window, and the dialog would drop as host_not_mounted instead.
    @Test("with attach, a dialog triggered under the app's full-screen modal drops as host_modal_open")
    func fullScreenModalIsHostModalOpen() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        SDKInstance.shared.onHostUnmounted(SDKInstance.testHostId)  // only the app's real host counts
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        presentFullScreen(over: root)
        try await sdk.waitUntil("UIKit takes the covered root out of the window") { root.view.window == nil }

        let blocked = try sdk.deliver("test_nudge_dialog")

        #expect(dropReason(blocked, sdk) == .hostModalOpen)
        root.dismiss(animated: false)
        try await sdk.settle(0.5)
    }

    // Fails if: the host gate drops a floater under the app's full-screen modal (host_not_mounted): floaters and
    // guides are outside the modal rule and are accepted as before.
    @Test("with attach, a floater triggered under the app's full-screen modal is not dropped")
    func fullScreenModalLetsAFloaterThrough() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/floater/floater_story_window.json"))
        defer { sdk.tearDown() }
        SDKInstance.shared.onHostUnmounted(SDKInstance.testHostId)
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        presentFullScreen(over: root)
        try await sdk.waitUntil("UIKit takes the covered root out of the window") { root.view.window == nil }

        let floater = try sdk.deliver("test_floater_story")

        #expect(dropReason(floater, sdk) == nil)
        root.dismiss(animated: false)
        try await sdk.waitUntil("the floater shows once the modal is closed") { floater.state == .displaying }
    }

    // Fails if: `DigiaHostView` tears its hosting controller down when it only left the window under the app's
    // full-screen modal: SwiftUI state on screen (an in-progress survey's answers) would be lost.
    @Test("with attach, the host keeps its SwiftUI layer across the app's full-screen modal")
    func fullScreenModalKeepsTheHostLayer() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        let host = try #require(root.view.subviews.last as? DigiaHostView)
        let layer = try #require(host.subviews.first)

        presentFullScreen(over: root)
        try await sdk.waitUntil("UIKit takes the covered root out of the window") { root.view.window == nil }
        root.dismiss(animated: false)
        try await sdk.waitUntil("the root is back in the window") { root.view.window != nil }

        #expect(host.subviews.first === layer)
    }

    // Fails if: without attach, the host gate answers host_not_mounted before looking for the app's modal: a
    // full-screen modal makes `DigiaHost` disappear, so the dialog would be misreported.
    @Test("without attach, a dialog triggered under the app's full-screen modal drops as host_modal_open")
    func fullScreenModalOverDigiaHostIsHostModalOpen() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        SDKInstance.shared.onHostUnmounted(SDKInstance.testHostId)
        try sdk.mount { Text("App home") }
        let root = try #require(ViewControllerUtil.keyWindow()?.rootViewController)
        presentFullScreen(over: root)
        try await sdk.waitUntil("UIKit takes the covered root out of the window") { root.view.window == nil }

        let blocked = try sdk.deliver("test_nudge_dialog")

        #expect(dropReason(blocked, sdk) == .hostModalOpen)
        root.dismiss(animated: false)
        try await sdk.settle(0.5)
    }

    // Fails if: `hostUnavailable` checks for an app modal only under attach. With a SwiftUI `DigiaHost`
    // the dialog would be drawn hidden under the app's sheet and count an impression.
    @Test("without attach, a dialog triggered while the app presents its own modal is dropped at once as host_modal_open")
    func appModalOverDigiaHostDropsAsHostModalOpen() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        try sdk.mount { Text("App home") }
        let root = try #require(ViewControllerUtil.keyWindow()?.rootViewController)
        root.present(AppScreen(), animated: false)
        ComponentTestHost.drainRunLoop(for: 0.3)

        let blocked = try sdk.deliver("test_nudge_dialog")

        #expect(dropReason(blocked, sdk) == .hostModalOpen)
        root.dismiss(animated: false)
        try await sdk.settle(0.5)
    }

    // Fails if: `showStoryOverlay` records the story as open before the present was accepted, or
    // `DigiaStoryPresenter.present` stops refusing a presenter mid-transition. The SDK would then
    // believe a story is open with nothing on screen, and `hasActiveOverlay` would block the app.
    @Test("with attach, a story opened while the top screen is still being presented is not recorded as open")
    func storyIntoATransitionIsNotRecordedAsOpen() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        let root = AppScreen()
        let window = makeWindow(root: root, sdk)
        Digia.attach(to: window)
        ComponentTestHost.drainRunLoop(for: 0.3)
        root.present(AppScreen(), animated: true)  // still being presented until its animation ends

        let shown = SDKInstance.shared.controller.showStoryOverlay(
            config: InlineStoryConfig(slotKey: "story_slot", items: []), initialIndex: 0,
            payload: CEPTriggerPayload(cepCampaignId: "cep-story", campaignKey: "story_test", cepMetadata: [:]))

        #expect(!shown)
        #expect(SDKInstance.shared.controller.activeStoryOverlay == nil)
        #expect(!Digia.hasActiveOverlay)
        #expect(sdk.records("story_test", reason: TimelineReason.storyPresentFailed).first?.extras["cause"]
            == "presenter_transitioning")
    }

    // Fails if: `showStoryOverlay` keeps the unchecked present for hosts other than attach (a SwiftUI
    // `DigiaHost` here): the story would be recorded as open with nothing on screen.
    @Test("without attach, a story opened while the top screen is still being presented is not recorded as open")
    func storyIntoATransitionIsNotRecordedAsOpenWithDigiaHost() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        try sdk.mount { Text("App home") }
        let root = try #require(ViewControllerUtil.keyWindow()?.rootViewController)
        root.present(AppScreen(), animated: true)  // still being presented until its animation ends

        let shown = SDKInstance.shared.controller.showStoryOverlay(
            config: InlineStoryConfig(slotKey: "story_slot", items: []), initialIndex: 0,
            payload: CEPTriggerPayload(cepCampaignId: "cep-story", campaignKey: "story_test", cepMetadata: [:]))

        #expect(!shown)
        #expect(SDKInstance.shared.controller.activeStoryOverlay == nil)
        #expect(sdk.records("story_test", reason: TimelineReason.storyPresentFailed).first?.extras["cause"]
            == "presenter_transitioning")
        root.dismiss(animated: false)
        try await sdk.settle(0.5)
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
