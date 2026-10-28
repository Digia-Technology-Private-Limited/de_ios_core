// tags: widget nudge campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Every way a nudge ends — closed, or dropped before it showed — and the exact chain each one sends, beside
/// what the CEP holding it sees. Real touches through `SdkHarness`.
///
/// Scrim and drag closes report `user_close` as coded: the nudge only tells apart the closes it marks
/// beforehand (CTA, auto-dismiss, screen exit).
///
/// platform note: the Dart twin is `test/campaign_behaviour/nudge_campaign_behaviour_test.dart`. Its system-back case has no
/// iOS counterpart: an iOS nudge has no back gesture.
@MainActor
@Suite("Nudge campaign behaviour", .serialized, .tags(.integration, .nudge, .analytics))
struct NudgeCampaignBehaviourTests {
    private let shownThenClosed = [Chain.triggered, Chain.viewed, Chain.dismissed]

    private func fixture(_ name: String) -> WorkspaceFixtures.Campaign {
        WorkspaceFixtures.campaign("campaigns/\(name.split(separator: "_").prefix(2).joined(separator: "_"))/\(name).json")
    }

    private func start(_ campaigns: [WorkspaceFixtures.Campaign]) async throws -> SdkHarness {
        try await SdkHarness.startChain(campaigns) { Text("App home") }
    }

    private func show(_ sdk: SdkHarness, _ text: String) async throws {
        try await sdk.waitUntil("\"\(text)\" on screen") { sdk.isShowing(text) }
    }

    // MARK: - Closed

    @Test("primary CTA: clicked, then dismissed as cta_action")
    func primaryCta() async throws {
        let sdk = try await start([fixture("nudge_dialog")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")

        try await sdk.tap(id: "dialogButton")  // "Got It"
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Test Nudge") }

        let events = await sdk.sent("test_nudge_dialog")
        expectChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.dismissed], reason: .ctaAction)
        #expect(propsOf(events, Chain.clicked)["cta_role"] as? String == "primary")
    }

    @Test("secondary CTA: Digia click only, dismissed as cta_action")
    func secondaryCta() async throws {
        let sdk = try await start([fixture("nudge_dialog_dual_cta")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog_dual_cta")
        try await show(sdk, "Confirm Action")

        try await sdk.tap(id: "dialogCancel")  // "Cancel"
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Confirm Action") }

        let events = await sdk.sent("test_nudge_dialog_dual_cta")
        expectChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.dismissed], reason: .ctaAction,
            // Only a primary CTA reaches the CEP as a click.
            cepClicks: 0)
        #expect(propsOf(events, Chain.clicked)["cta_role"] as? String == "secondary")
    }

    @Test("close button: dismissed as user_close, no click")
    func closeButton() async throws {
        let sdk = try await start([fixture("nudge_dialog_close_inside")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog_close_inside")
        try await show(sdk, "Inside Close Dialog")

        try await sdk.tap(label: "Close")
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Inside Close Dialog") }

        expectChain(await sdk.sent("test_nudge_dialog_close_inside"), d, names: shownThenClosed, reason: .userClose)
    }

    @Test("backdrop tap: dismissed as user_close, as coded")
    func backdropTap() async throws {
        let sdk = try await start([fixture("nudge_dialog_backdrop_on")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog_backdrop_on")
        try await show(sdk, "Backdrop Tap Dialog")
        try await sdk.settle(0.4)

        // The scrim, well clear of the centred card.
        try await sdk.touch(CGPoint(x: 24, y: 140))
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Backdrop Tap Dialog") }

        expectChain(await sdk.sent("test_nudge_dialog_backdrop_on"), d, names: shownThenClosed, reason: .userClose)
    }

    @Test("auto-dismiss: dismissed as auto_timeout", .tags(.slow))
    func autoDismiss() async throws {
        let sdk = try await start([fixture("nudge_dialog_auto_dismiss")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog_auto_dismiss")
        try await show(sdk, "Auto Dismiss Dialog")

        // The fixture's autoDismissAfterMs is 5000.
        try await sdk.waitUntil("the dialog has timed out", timeout: 7) { !sdk.isShowing("Auto Dismiss Dialog") }

        expectChain(await sdk.sent("test_nudge_dialog_auto_dismiss"), d, names: shownThenClosed, reason: .autoTimeout)
    }

    @Test("bottom sheet drag: dismissed as user_close, as coded")
    func bottomSheetDrag() async throws {
        let sdk = try await start([fixture("nudge_bottomsheet_drag_dismiss")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_bottomsheet_drag_dismiss")
        try await show(sdk, "Drag To Dismiss")

        // `TouchSynthesizer` taps but cannot drag; past its threshold the sheet calls `NudgeSheetView`'s
        // dismiss, which is this.
        SDKInstance.shared.markNudgeDismissed()
        try await sdk.waitUntil("the sheet is gone") { !sdk.isShowing("Drag To Dismiss") }

        expectChain(
            await sdk.sent("test_nudge_bottomsheet_drag_dismiss"), d, names: shownThenClosed, reason: .userClose)
    }

    @Test("full screen close button: dismissed as user_close")
    func fullScreenCloseButton() async throws {
        let sdk = try await start([fixture("nudge_fullscreen_close_button")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_fullscreen_close_button")
        try await show(sdk, "FullScreen Takeover")

        try await sdk.tap(label: "Close")
        try await sdk.waitUntil("the takeover is gone") { !sdk.isShowing("FullScreen Takeover") }

        expectChain(
            await sdk.sent("test_nudge_fullscreen_close_button"), d, names: shownThenClosed, reason: .userClose)
    }

    @Test("leaving its screen: dismissed as screen_exit")
    func leavingItsScreen() async throws {
        let key = "test_nudge_dialog_screen_change_home_only"
        let sdk = try await start([fixture("nudge_dialog_screen_change_home_only")])
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "home")
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Dialog Screen Change Home Only")

        Digia.setCurrentScreen(name: "search")
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Screen Change Home Only") }

        expectChain(await sdk.sent(key), d, names: shownThenClosed, reason: .screenExit)
    }

    @Test("CEP cancel while showing: dismissed as cancelled")
    func cepCancelWhileShowing() async throws {
        let sdk = try await start([fixture("nudge_dialog")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")

        d.presentation.cancel()
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Test Nudge") }

        expectChain(await sdk.sent("test_nudge_dialog"), d, names: shownThenClosed, reason: .cancelled)
    }

    @Test("after a CEP cancel, the next nudge shows alone")
    func nextNudgeAfterCepCancel() async throws {
        let sdk = try await start([fixture("nudge_dialog"), fixture("nudge_dialog_backdrop_on")])
        defer { sdk.tearDown() }
        let cancelled = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")
        cancelled.presentation.cancel()
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Test Nudge") }

        let next = try sdk.deliverChain("test_nudge_dialog_backdrop_on")
        try await show(sdk, "Backdrop Tap Dialog")
        #expect(!sdk.isShowing("Dialog Test Nudge"))
        #expect(next.timeline == ["displayed"])
    }

    // MARK: - Backdrop off

    // A bottom sheet authored `backdropDismissible: false`, `draggable: false`: only its Dismiss button (primary,
    // `Action.hideBottomSheet`) ends it.

    private let backdropOffKey = "test_nudge_bottomsheet_backdrop_off"
    private let backdropOffTitle = "Backdrop Tap Dismiss Off"

    private func showBackdropOff() async throws -> (SdkHarness, Delivery) {
        let sdk = try await start([fixture("nudge_bottomsheet_backdrop_off")])
        let d = try sdk.deliverChain(backdropOffKey)
        try await show(sdk, backdropOffTitle)
        // Past the sheet's presentation, so a position read now is where it rests.
        try await sdk.settle(1)
        return (sdk, d)
    }

    /// Asserts it is still up and only shown: Viewed, and the CEP still held.
    private func expectStillShown(_ sdk: SdkHarness, _ d: Delivery, sourceLocation: SourceLocation = #_sourceLocation)
        async
    {
        #expect(sdk.isShowing(backdropOffTitle), sourceLocation: sourceLocation)
        let events = await sdk.sent(backdropOffKey)
        #expect(names(events) == [Chain.triggered, Chain.viewed], sourceLocation: sourceLocation)
        #expect(
            propsOf(events, Chain.viewed, sourceLocation: sourceLocation)["display_style"] as? String == "bottom_sheet",
            sourceLocation: sourceLocation)
        #expect(d.timeline == ["displayed"], "still showing, still holding the CEP", sourceLocation: sourceLocation)
    }

    /// Drags the sheet down by its title.
    private func dragSheetDown(_ sdk: SdkHarness) async throws -> (before: CGPoint, after: CGPoint) {
        let window = try #require(sdk.window)
        let before = try #require(UIProbe.center(ofText: backdropOffTitle, in: window))
        try await sdk.swipe(from: before, to: CGPoint(x: before.x, y: before.y + 300))
        return (before, try #require(UIProbe.center(ofText: backdropOffTitle, in: window)))
    }

    @Test("backdrop off: a scrim tap does nothing")
    func backdropOffScrimTap() async throws {
        let (sdk, d) = try await showBackdropOff()
        defer { sdk.tearDown() }

        try await sdk.touch(CGPoint(x: 24, y: 140))

        await expectStillShown(sdk, d)
    }

    // As coded: `draggable: false` holds the sheet where it is; it does not even move to snap back.
    @Test("backdrop off: a drag down does nothing, as coded")
    func backdropOffDragDown() async throws {
        let (sdk, d) = try await showBackdropOff()
        defer { sdk.tearDown() }

        let (before, after) = try await dragSheetDown(sdk)
        #expect(abs(after.y - before.y) < 1, "the sheet did not move")

        await expectStillShown(sdk, d)
    }

    @Test("backdrop off: the Dismiss button closes it as cta_action")
    func backdropOffDismissButton() async throws {
        let (sdk, d) = try await showBackdropOff()
        defer { sdk.tearDown() }
        try await sdk.touch(CGPoint(x: 24, y: 140))
        _ = try await dragSheetDown(sdk)

        try await sdk.tap(id: "button")  // "Dismiss"
        try await sdk.waitUntil("the sheet is gone") { !sdk.isShowing(backdropOffTitle) }

        let events = await sdk.sent(backdropOffKey)
        expectChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.dismissed], reason: .ctaAction)
        let clicked = propsOf(events, Chain.clicked)
        #expect(clicked["element_id"] as? String == "cta_primary")
        #expect(clicked["cta_role"] as? String == "primary")
        #expect(clicked["cta_label"] as? String == "Dismiss")
        #expect(clicked["action_type"] as? String == "dismiss")
        #expect(d.signals.compactMap { if case .clicked(let id) = $0 { id } else { nil } } == ["cta_primary"])
    }

    // MARK: - Dropped

    @Test("off its target screen: screen_not_targeted")
    func offTargetScreen() async throws {
        let key = "test_nudge_dialog_screen_change_home_only"
        let sdk = try await start([fixture("nudge_dialog_screen_change_home_only")])
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "search")
        let d = try sdk.deliverChain(key)
        try await sdk.settle()
        #expect(!sdk.isShowing("Dialog Screen Change Home Only"))

        expectDropped(await sdk.sent(key), d, .screenNotTargeted)
    }

    @Test("over its cap: frequency_capped, and the first chain intact")
    func overItsCap() async throws {
        let base = fixture("nudge_dialog")
        var json = base.json
        json["frequency"] = ["maxTotal": NSNumber(value: 1)] as [String: any Sendable]
        let sdk = try await start([WorkspaceFixtures.Campaign(name: base.name, json: json)])
        defer { sdk.tearDown() }
        let first = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")
        try await sdk.tap(id: "dialogButton")
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Test Nudge") }

        let second = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.settle()
        #expect(!sdk.isShowing("Dialog Test Nudge"))

        let events = await sdk.sent("test_nudge_dialog")
        func of(_ d: Delivery) -> [WireEvent] {
            events.filter { $0["impression_id"] as? String == d.presentation.id }
        }
        expectChain(
            of(first), first, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.dismissed],
            reason: .ctaAction)
        expectDropped(of(second), second, .frequencyCapped)
        #expect(propsOf(of(second), Chain.dropped)["cap_limit"] as? Int == 1)
    }

    @Test("a nudge already up: surface_busy, the incumbent untouched")
    func surfaceBusy() async throws {
        let sdk = try await start([fixture("nudge_dialog"), fixture("nudge_dialog_backdrop_on")])
        defer { sdk.tearDown() }
        let incumbent = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")

        let blocked = try sdk.deliverChain("test_nudge_dialog_backdrop_on")
        try await sdk.settle()
        #expect(sdk.isShowing("Dialog Test Nudge"))

        let events = await sdk.sent("test_nudge_dialog_backdrop_on")
        expectDropped(events, blocked, .surfaceBusy)
        #expect(propsOf(events, Chain.dropped)["blocking_campaign_key"] as? String == "test_nudge_dialog")
        #expect(names(await sdk.sent("test_nudge_dialog")) == [Chain.triggered, Chain.viewed])
        #expect(incumbent.outcome == nil)
        #expect(!incumbent.isHoldReleased, "a modal holds while it shows")
    }

    @Test("CEP cancel before it shows: cancelled")
    func cepCancelBeforeShowing() async throws {
        let sdk = try await start([fixture("nudge_dialog")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        d.presentation.cancel()
        try await sdk.settle()
        #expect(!sdk.isShowing("Dialog Test Nudge"))

        expectDropped(await sdk.sent("test_nudge_dialog"), d, .cancelled)
    }

    @Test("a malformed campaign never enters the store: unknown_campaign_key, nothing sent")
    func malformedCampaign() async throws {
        let base = fixture("nudge_dialog")
        var json = base.json
        json["templateConfig"] = ["templateType": "mystery"] as [String: any Sendable]
        let sdk = try await start([WorkspaceFixtures.Campaign(name: base.name, json: json)])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.settle()

        expectDropped(await sdk.sent("test_nudge_dialog"), d, .unknownCampaignKey, sendsEvents: false)
    }

    @Test("an unknown key: unknown_campaign_key, nothing sent")
    func unknownKey() async throws {
        let sdk = try await start([fixture("nudge_dialog")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_no_such_campaign")
        try await sdk.settle()

        expectDropped(await sdk.sent("test_no_such_campaign"), d, .unknownCampaignKey, sendsEvents: false)
    }

    // MARK: - Dropped before the SDK is ready

    // The SDK knows no campaign yet, so a delivery in these states sends nothing to Digia: only the CEP hears.

    @Test("D1 delivered before Digia.initialize: not_initialized, nothing sent")
    func beforeInitialize() async throws {
        let sdk = try await SdkHarness.startUninitialized()
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.settle()

        #expect(!sdk.isShowing("Dialog Test Nudge"))
        expectDropped(try await sdk.sentToScriptedNetwork("test_nudge_dialog"), d, .notInitialized, sendsEvents: false)
        #expect(d.dropDetail == "Digia.initialize() has not been called")
    }

    @Test("D2 delivered while the campaign fetch is held open: not_ready, nothing sent, and not shown once it lands")
    func whileFetchHeld() async throws {
        let sdk = try await SdkHarness.startFetchHeld(fixture("nudge_dialog"))
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.settle()

        expectDropped(try await sdk.sentToScriptedNetwork("test_nudge_dialog"), d, .notReady, sendsEvents: false)
        #expect(d.dropDetail == "Campaigns are still loading; trigger dropped")

        // Core never holds a trigger: the campaign does not appear when the fetch finishes.
        try await sdk.releaseBundle()
        try await sdk.settle(0.5)
        #expect(!sdk.isShowing("Dialog Test Nudge"))
        #expect(try await sdk.sentToScriptedNetwork("test_nudge_dialog").isEmpty)
    }

    @Test("D3 delivered after the campaign fetch failed: initialization_failed, nothing sent")
    func afterFetchFailed() async throws {
        let sdk = try await SdkHarness.startFetchFailed(fixture("nudge_dialog"))
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.settle()

        #expect(!sdk.isShowing("Dialog Test Nudge"))
        expectDropped(try await sdk.sentToScriptedNetwork("test_nudge_dialog"), d, .initializationFailed, sendsEvents: false)
        #expect(d.dropDetail == "Campaign fetch failed; trigger dropped")
    }

    // MARK: - Dropped or ended by the plugin and the watchdog

    // As coded: the SDK has no check for a missing `DigiaHost` (`host_not_mounted` is only the React Native
    // guide renderer's), so a nudge with no host to draw it waits out the 15 s acceptance watchdog and drops
    // `timeout`. This is also the one `timeout` reachable through the CEP flow in real time.
    @Test("D6 D7 no DigiaHost mounted: the nudge never shows and drops timeout after 15 s, as coded", .tags(.slow))
    func noHostMountedTimesOut() async throws {
        let campaign = fixture("nudge_dialog")
        let sdk = try await SdkHarness.startWithoutHost(campaign)
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.waitUntil("the acceptance watchdog", timeout: 20) { d.outcome != nil }

        #expect(!sdk.isShowing("Dialog Test Nudge"))
        expectDroppedWire(
            try await sdk.sentToScriptedNetwork("test_nudge_dialog"), d, .timeout, campaign, screen: nil,
            extras: ["surface_kind": "nudge", "timeout_ms": 15000, "app_backgrounded": false],
            detail: "never displayed within the acceptance window")
    }

    // As coded: the CEP's outcome is `dismissed(plugin_detached)`; Digia is told nothing and the nudge stays up
    // until the user closes it (the replaced plugin only loses its slot).
    @Test("D16 the CEP plugin is replaced while a nudge shows: the CEP hears plugin_detached, as coded")
    func pluginDetachedWhileShowing() async throws {
        let campaign = fixture("nudge_dialog")
        let sdk = try await start([campaign])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")

        Digia.register(FakeCep())
        try await sdk.settle()

        #expect(d.timeline == ["displayed", "hold", "outcome"])
        #expect(d.outcome == .dismissed(reason: .pluginDetached, completed: false))
        #expect(names(await sdk.sent("test_nudge_dialog")) == [Chain.triggered, Chain.viewed])
        #expect(sdk.isShowing("Dialog Test Nudge"), "the nudge stays on screen")
    }

    // MARK: - Drags and a double tap

    // `DigiaBottomSheet` closes on distance alone (`shouldDismissBottomSheet`: at least 120 pt or a quarter of
    // the sheet's height), never on velocity.

    /// The sheet's title, settled where it rests: where a finger grabs the sheet, and how far it has moved.
    private func restingTitle(_ sdk: SdkHarness, _ title: String) async throws -> CGRect {
        try await sdk.waitUntilSteady(text: title)
        return try #require(sdk.frame(text: title))
    }

    @Test("bottom sheet: a short drag springs back and sends nothing; a long one closes it as user_close")
    func sheetDragSnapBackThenClose() async throws {
        let key = "test_nudge_bottomsheet_drag_snap_back"
        let title = "Drag Snap Back Test"
        let sdk = try await start([fixture("nudge_bottomsheet_drag_snap_back")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, title)
        let resting = try await restingTitle(sdk, title)

        // 60 pt, short of the 120 pt minimum, over 320 ms.
        try sdk.drag(from: CGPoint(x: resting.midX, y: resting.midY), by: CGVector(dx: 0, dy: 60))
        let back = try await restingTitle(sdk, title)
        #expect(abs(back.minY - resting.minY) < 1, "the sheet springs back")
        #expect(names(await sdk.sent(key)) == [Chain.triggered, Chain.viewed], "a snap back sends nothing")
        #expect(d.timeline == ["displayed"], "still showing, still holding the CEP")

        // 300 pt: past the threshold.
        try sdk.drag(from: CGPoint(x: back.midX, y: back.midY), by: CGVector(dx: 0, dy: 300))
        try await sdk.waitUntil("the sheet is gone") { !sdk.isShowing(title) }

        let events = await sdk.sent(key)
        expectChain(events, d, names: shownThenClosed, reason: .userClose)
        #expect(propsOf(events, Chain.viewed)["display_style"] as? String == "bottom_sheet")
    }

    // As coded: velocity never closes an iOS sheet, so a fast flick short of the threshold springs back.
    @Test("bottom sheet: a fast short flick downward springs back, as coded")
    func sheetFastShortFlick() async throws {
        let key = "test_nudge_bottomsheet_drag_dismiss"
        let title = "Drag To Dismiss"
        let sdk = try await start([fixture("nudge_bottomsheet_drag_dismiss")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, title)
        let resting = try await restingTitle(sdk, title)

        // 60 pt in 3 moves of 16 ms: well over 1000 pt/s.
        try sdk.drag(from: CGPoint(x: resting.midX, y: resting.midY), by: CGVector(dx: 0, dy: 60), steps: 3)
        let after = try await restingTitle(sdk, title)

        #expect(abs(after.minY - resting.minY) < 1, "the sheet springs back")
        #expect(sdk.isShowing(title))
        #expect(names(await sdk.sent(key)) == [Chain.triggered, Chain.viewed])
        #expect(d.timeline == ["displayed"], "still showing, still holding the CEP")
        #expect(d.outcome == nil)
    }

    // Fails today: the second tap during the close sends a second Clicked and a second CEP click (expected one each).
    @Test("primary CTA tapped twice quickly: one Clicked, one Dismissed")
    func primaryCtaDoubleTap() async throws {
        let sdk = try await start([fixture("nudge_dialog")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")
        // Settled for 400 ms first, as `tap(id:)` waits, so both touches land on the button.
        try await sdk.waitUntilSteady("the CTA settled") { sdk.frame(id: "dialogButton") }
        let button = try #require(sdk.frame(id: "dialogButton"))
        let window = try #require(sdk.window)

        // Two real touches 200 ms apart ("Got It").
        try TouchSynthesizer.tap(at: CGPoint(x: button.midX, y: button.midY), in: window)
        try TouchSynthesizer.tap(at: CGPoint(x: button.midX, y: button.midY), in: window)
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Test Nudge") }

        let events = await sdk.sent("test_nudge_dialog")
        expectChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.dismissed], reason: .ctaAction)
        let clicked = propsOf(events, Chain.clicked)
        #expect(clicked["element_id"] as? String == "cta_primary")
        #expect(clicked["cta_role"] as? String == "primary")
        #expect(d.signals.compactMap { if case .clicked(let id) = $0 { id } else { nil } } == ["cta_primary"])
    }
}
