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
        await sdk.settle(0.4)

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

    // Fails today: the dialog closes and the CEP gets dismissed(cancelled), but no Digia Dismissed is sent; dismissSurfaces(for:) calls controller.dismissNudge(), not markNudgeDismissed
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
        await sdk.settle(1)
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
        await sdk.settle()
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
        await sdk.settle()
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
        await sdk.settle()
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
        await sdk.settle()
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
        await sdk.settle()

        expectDropped(await sdk.sent("test_nudge_dialog"), d, .unknownCampaignKey, sendsEvents: false)
    }

    @Test("an unknown key: unknown_campaign_key, nothing sent")
    func unknownKey() async throws {
        let sdk = try await start([fixture("nudge_dialog")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_no_such_campaign")
        await sdk.settle()

        expectDropped(await sdk.sent("test_no_such_campaign"), d, .unknownCampaignKey, sendsEvents: false)
    }
}
