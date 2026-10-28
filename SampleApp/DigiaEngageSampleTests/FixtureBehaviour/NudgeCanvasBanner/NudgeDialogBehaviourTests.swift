import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// What a touch does to a dialog nudge, and how wide it is drawn: the close button inside or
/// floating below it, the backdrop, the authored width held inside the horizontal margin, and a
/// dialog taller than the room it has. Fixtures: `nudge_dialog/nudge_dialog_close_inside`,
/// `_close_outside_bottom`, `_backdrop_on`, `_backdrop_off`, `_width_narrow`, `_width_wide`,
/// `_margin_large`, `_margin_zero`, `_tall_content`, each delivered through the real SDK and
/// driven with real touches. iOS draws the dialog inline in `NudgeOverlayView`
/// (`NudgeDialogContainer`).
///
/// Port of `flutter/core/test/fixture_behaviour/ui_nudge_test.dart` (group "a dialog").
@Suite("Nudge: dialog behaviour", .serialized,
       .tags(.integration, .behaviour, .nudge))
@MainActor
struct NudgeDialogBehaviourTests {

    private static let dialogs = "nudge_dialog/nudge_dialog_"

    private func show(_ name: String, title: String) async throws -> SdkHarness {
        try await SdkHarness.showNudge(fixture(Self.dialogs + name), title: title)
    }

    // Fails if: NudgeOverlayView.swift `canvasDialogPanel` stops drawing the inside
    // `CanvasNudgeCloseOverlay`, or the `.overlayPreferenceValue` outside one loses `action: dismiss`.
    @Test("closes from a close button inside it or floating below it",
          arguments: [("close_inside", "Inside Close Dialog"),
                      ("close_outside_bottom", "Floating Close Dialog")])
    func closeButtonCloses(name: String, title: String) async throws {
        let sdk = try await show(name, title: title)
        defer { sdk.tearDown() }

        try await sdk.tapCloseButton()

        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing(title) }
        #expect(SDKInstance.shared.controller.activeNudge == nil)
    }

    // Fails if: NudgeOverlayView.swift `NudgeDialogContainer.handleBackdropTap` stops calling
    // `dismiss()`.
    @Test("closes on a tap outside it when the backdrop dismisses")
    func backdropTapCloses() async throws {
        let sdk = try await show("backdrop_on", title: "Backdrop Tap Dialog")
        defer { sdk.tearDown() }

        try sdk.tap(at: CGPoint(x: 10, y: 10))

        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Backdrop Tap Dialog") }
        #expect(SDKInstance.shared.controller.activeNudge == nil)
    }

    // Fails if: NudgeOverlayView.swift `handleBackdropTap` loses `if surface.backdropDismissible`.
    @Test("stays on a tap outside it when the backdrop is locked")
    func lockedBackdropStays() async throws {
        let sdk = try await show("backdrop_off", title: "Locked Dialog")
        defer { sdk.tearDown() }

        try sdk.tap(at: CGPoint(x: 10, y: 10))

        try await sdk.settle(0.6)
        #expect(sdk.isShowing("Locked Dialog"))
        #expect(SDKInstance.shared.controller.activeNudge != nil)
    }

    /// The width the dialog's canvas is drawn at, read off its full-width-relative CTA
    /// (`dialogButton`): its on-screen width over the fraction of the canvas it was authored at.
    private func shownCanvasWidth(_ name: String, title: String) async throws -> CGFloat {
        let campaign = try fixture(Self.dialogs + name)
        let sdk = try await SdkHarness.showNudge(campaign, title: title)
        defer { sdk.tearDown() }
        let canvas = try #require((campaign["templateConfig"] as? [String: Any])?["canvas"] as? [String: Any])
        let children = try #require(canvas["children"] as? [[String: Any]])
        let button = try #require(children.first { $0["id"] as? String == "dialogButton" })
        let fraction = try #require((button["rect"] as? [String: Any])?["width"] as? Double)
        let frame = try #require(sdk.frame(id: "dialogButton"))
        return frame.width / fraction
    }

    // Flutter uses a 360 px window, the design width, so one canvas px is one screen px. The
    // simulator's screen is wider, so every expectation here is the same canvas px times the
    // screen's design scale (width / 360, below the 1.15 upscale cap on phones).
    // Fails if: NudgeOverlayView.swift `NudgeDialogContainer` stops narrowing `availableSize` by
    // `2 * horizontalMargin`, or stops reading `minHorizontalMargin`.
    @Test("is as wide as its canvas, held inside its horizontal margin")
    func widthHeldInsideTheMargin() async throws {
        let scale = min(UIScreen.main.bounds.width / 360, 1.15)
        func shown(_ px: CGFloat) -> CGFloat { px * scale }

        let narrow = try await shownCanvasWidth("width_narrow", title: "Narrow Alert Dialog")
        #expect(abs(narrow - shown(260)) < 1, "narrower than the room: authored width")
        let wide = try await shownCanvasWidth("width_wide", title: "Wide Modal Dialog")
        #expect(abs(wide - shown(312)) < 1, "340 authored, held to 360 - 2 x 24")
        let large = try await shownCanvasWidth("margin_large", title: "Constrained Margin Dialog")
        #expect(abs(large - shown(264)) < 1, "320 authored, margin 48: 360 - 2 x 48")
        let zero = try await shownCanvasWidth("margin_zero", title: "Edge-to-Edge Margin Dialog")
        #expect(abs(zero - shown(360)) < 1, "margin 0 lets 360 reach both edges")
    }

    // Flutter shrinks the window to 640 px under a 760 px canvas. The simulator's window cannot be
    // resized; at the design scale the 760 px canvas is about as tall as the whole screen, so the
    // same relationship is held on the real screen: the CTA ends on screen and takes the tap.
    // Fails if: CampaignCanvasView.swift `fittedScale` stops taking
    // `availableSize.height / naturalHeight` into account (the button would be off screen).
    @Test("fits a screen shorter than its canvas, button reachable")
    func tallDialogFitsTheScreen() async throws {
        let sdk = try await show("tall_content", title: "Terms & Privacy Update")
        defer { sdk.tearDown() }

        let button = try #require(sdk.frame(id: "dialogButton"))
        #expect(button.maxY <= sdk.screenSize.height, "on screen")

        try await sdk.tap(id: "dialogButton")

        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Terms & Privacy Update") }
    }
}
}
