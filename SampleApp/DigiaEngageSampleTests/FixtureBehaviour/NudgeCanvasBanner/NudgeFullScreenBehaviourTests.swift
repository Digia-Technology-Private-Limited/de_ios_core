import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// What a touch does to a full-screen nudge: the close button on the side it was authored, and a
/// forced takeover with no close button that only its CTA leaves. Fixtures:
/// `nudge_fullscreen/nudge_fullscreen_close_button`, `_close_top_left`, `_forced`, delivered
/// through the real SDK (a `fullScreenCover`, `NudgeFullScreenView`) and driven with real touches.
///
/// Port of `flutter/core/test/fixture_behaviour/ui_nudge_test.dart` (group "a full-screen nudge").
@Suite("Nudge: full-screen behaviour", .serialized,
       .tags(.integration, .behaviour, .nudge))
@MainActor
struct NudgeFullScreenBehaviourTests {

    private static let fullscreens = "nudge_fullscreen/nudge_fullscreen_"

    // Fails if: NudgeCloseButtonPlacement.swift stops honouring `horizontal` (both buttons would
    // land on one side), or NudgeOverlayView.swift `NudgeFullScreenView` loses `action: dismiss`.
    @Test("puts its close button on the authored side and closes",
          arguments: [("close_button", "FullScreen Takeover", true),
                      ("close_top_left", "Back Style Close FullScreen", false)])
    func closeButtonSide(name: String, title: String, onTheRight: Bool) async throws {
        let sdk = try await SdkHarness.showNudge(fixture(Self.fullscreens + name), title: title)
        defer { sdk.tearDown() }
        try await sdk.waitUntilSteady("the close button settled") { sdk.closeButtonFrame }
        let close = try #require(sdk.closeButtonFrame)
        let middle = sdk.screenSize.width / 2

        if onTheRight {
            #expect(close.midX > middle, "top-right")
        } else {
            #expect(close.midX < middle, "top-left")
        }
        #expect(close.midY < sdk.screenSize.height / 2, "at the top")

        try await sdk.tapCloseButton()

        try await sdk.waitUntil("the nudge is gone") { !sdk.isShowing(title) }
        #expect(SDKInstance.shared.controller.activeNudge == nil)
    }

    // Fails if: NudgeOverlayView.swift `NudgeFullScreenView` draws a close button without
    // `surface.showCloseButton`, or drops the `.onTapGesture {}` that keeps empty bands from
    // reaching anything behind the takeover.
    @Test("has no close button unless it asks for one; only its CTA leaves")
    func forcedTakeover() async throws {
        let sdk = try await SdkHarness.showNudge(
            fixture(Self.fullscreens + "forced"), title: "Mandatory Action Interstitial")
        defer { sdk.tearDown() }

        #expect(sdk.closeButton == nil)
        try sdk.tap(at: CGPoint(x: sdk.screenSize.width / 2, y: 10))
        try await sdk.settle(0.6)
        #expect(sdk.isShowing("Mandatory Action Interstitial"), "there is no backdrop to tap")
        #expect(SDKInstance.shared.controller.activeNudge != nil)

        try await sdk.tap(id: "fsButton")

        try await sdk.waitUntil("the nudge is gone") { !sdk.isShowing("Mandatory Action Interstitial") }
        #expect(SDKInstance.shared.controller.activeNudge == nil)
    }
}

/// Auto-dismiss on every nudge surface: `nudge_bottomsheet_auto_dismiss`,
/// `nudge_dialog_auto_dismiss` and `nudge_fullscreen_auto_dismiss` each author
/// `autoDismissAfterMs: 5000`. The timer starts when the nudge appears
/// (`DigiaOverlayController.startNudgeAutoDismiss`), so the clock here starts once it is on screen.
/// Real time: the simulator has no fake clock, so each case takes about six seconds.
///
/// Port of `flutter/core/test/fixture_behaviour/ui_nudge_test.dart` (group "auto-dismiss").
@Suite("Nudge: auto-dismiss", .serialized,
       .tags(.integration, .behaviour, .nudge))
@MainActor
struct NudgeAutoDismissTests {

    // Fails if: DigiaOverlayController.swift `startNudgeAutoDismiss` stops waiting `afterMs`
    // (an early close fails the 4.5 s check, a missing one the wait for it to go).
    @Test("closes after the 5 s it authored, not before",
          arguments: [("nudge_bottomsheet/nudge_bottomsheet_auto_dismiss", "Auto Dismiss Test"),
                      ("nudge_dialog/nudge_dialog_auto_dismiss", "Auto Dismiss Dialog"),
                      ("nudge_fullscreen/nudge_fullscreen_auto_dismiss", "Auto Dismiss FullScreen")])
    func closesAfterFiveSeconds(path: String, title: String) async throws {
        let campaign = try fixture(path)
        let sdk = try await SdkHarness.start(campaign)
        defer { sdk.tearDown() }
        try sdk.mount { Text("App home") }
        let presentation = try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntil("the nudge is on screen") { sdk.isShowing(title) }
        let shownAt = Date()

        try await sdk.settle(4.5)
        #expect(sdk.isShowing(title), "still up 4.5 s in")
        #expect(SDKInstance.shared.controller.activeNudge != nil)

        try await sdk.waitUntil("the nudge closes itself", timeout: 3) { !sdk.isShowing(title) }
        let shownFor = Date().timeIntervalSince(shownAt)
        #expect(shownFor < 6.5, "closed within a beat of 5 s, after \(shownFor) s")
        #expect(SDKInstance.shared.controller.activeNudge == nil)
        #expect(presentation.dismissReason == .autoTimeout)
    }
}
}
