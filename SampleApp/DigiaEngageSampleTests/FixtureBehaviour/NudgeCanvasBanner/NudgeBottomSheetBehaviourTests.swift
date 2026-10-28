import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// What a touch does to a bottom-sheet nudge: the drag distance that closes it, the backdrop, the
/// close button and how a sheet taller than the room it has still fits. Every sheet is a shared
/// `nudge_bottomsheet/nudge_bottomsheet_*` fixture (`drag_dismiss`, `drag_snap_back`, `compact`,
/// `tall_content`, `backdrop_on`, `backdrop_off`, `close_button`, `close_button_styled`) delivered
/// through the real SDK and driven with real touches and drags.
///
/// iOS presents the sheet in a `fullScreenCover` (`NudgeOverlayView.swift`) drawing
/// `DigiaBottomSheet`, whose dismiss rule is `shouldDismissBottomSheet`: at least 120 pt or a
/// quarter of the sheet's height, never velocity.
///
/// Port of `flutter/core/test/fixture_behaviour/ui_nudge_test.dart` (group "a bottom sheet").
@Suite("Nudge: bottom sheet behaviour", .serialized,
       .tags(.integration, .behaviour, .nudge))
@MainActor
struct NudgeBottomSheetBehaviourTests {

    private static let sheets = "nudge_bottomsheet/nudge_bottomsheet_"

    private func show(_ name: String, title: String) async throws -> SdkHarness {
        try await SdkHarness.showNudge(fixture(Self.sheets + name), title: title)
    }

    /// Where a finger grabs the sheet: on its title, as a user grabs the top of a sheet.
    private func grab(_ sdk: SdkHarness, _ title: String) throws -> CGPoint {
        let frame = try #require(sdk.frame(text: title))
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func top(_ sdk: SdkHarness, _ title: String) throws -> CGFloat {
        try #require(sdk.frame(text: title)).minY
    }

    // Fails if: DigiaBottomSheet.swift `handleDragEnd` stops calling `close()` past the threshold.
    @Test("closes when dragged down past the threshold")
    func closesPastTheThreshold() async throws {
        // Only the drag can close it: the fixture locks its backdrop.
        let sdk = try await show("drag_dismiss", title: "Drag To Dismiss")
        defer { sdk.tearDown() }

        try sdk.drag(from: try grab(sdk, "Drag To Dismiss"), by: CGVector(dx: 0, dy: 200))

        try await sdk.waitUntil("the sheet is gone") { !sdk.isShowing("Drag To Dismiss") }
        #expect(SDKInstance.shared.controller.activeNudge == nil)
        #expect(sdk.isShowing("App home"))
    }

    // Fails if: DigiaBottomSheet.swift `handleDragChange` stops setting `dragOffset` (the sheet
    // would not follow the finger), or `handleDragEnd` stops animating it back to 0.
    @Test("follows the finger and springs back when released short of the threshold")
    func springsBackShortOfTheThreshold() async throws {
        let sdk = try await show("drag_snap_back", title: "Drag Snap Back Test")
        defer { sdk.tearDown() }
        let resting = try top(sdk, "Drag Snap Back Test")

        let drag = try sdk.drag(
            from: try grab(sdk, "Drag Snap Back Test"), by: CGVector(dx: 0, dy: 80), release: false)
        TouchSynthesizer.drainRunLoop(for: 0.1)
        #expect(try top(sdk, "Drag Snap Back Test") > resting + 40, "the sheet follows the finger")
        try drag.release()

        try await sdk.waitUntilSteady(text: "Drag Snap Back Test")
        #expect(sdk.isShowing("Drag Snap Back Test"))
        #expect(abs(try top(sdk, "Drag Snap Back Test") - resting) < 1)
        #expect(SDKInstance.shared.controller.activeNudge != nil)
    }

    // Fails if: DigiaBottomSheet.swift `handleDragEnd` starts dismissing on the drag's velocity
    // (e.g. `value.predictedEndTranslation`) instead of its distance.
    @Test("is not closed by a fast flick that falls short")
    func fastFlickFallsShort() async throws {
        let sdk = try await show("drag_snap_back", title: "Drag Snap Back Test")
        defer { sdk.tearDown() }
        let resting = try top(sdk, "Drag Snap Back Test")

        // 60 pt in 3 moves of 16 ms: well over 1000 pt/s.
        try sdk.drag(from: try grab(sdk, "Drag Snap Back Test"), by: CGVector(dx: 0, dy: 60), steps: 3)

        try await sdk.waitUntilSteady(text: "Drag Snap Back Test")
        #expect(sdk.isShowing("Drag Snap Back Test"), "velocity alone never dismisses")
        #expect(abs(try top(sdk, "Drag Snap Back Test") - resting) < 1)
    }

    // Fails if: DigiaBottomSheet.swift `minimumBottomSheetDismissDistance` is raised above 150, or
    // `shouldDismissBottomSheet` stops taking the larger of it and a quarter of the height.
    @Test("a short sheet closes at the 120 pt minimum")
    func shortSheetClosesAtTheMinimum() async throws {
        // 240 canvas px tall: a quarter is ~65 pt on screen, so the 120 pt floor decides.
        let sdk = try await show("compact", title: "Quick Notice")
        defer { sdk.tearDown() }

        try sdk.drag(from: try grab(sdk, "Quick Notice"), by: CGVector(dx: 0, dy: 150))

        try await sdk.waitUntil("the sheet is gone") { !sdk.isShowing("Quick Notice") }
        #expect(SDKInstance.shared.controller.activeNudge == nil)
    }

    // Fails if: DigiaBottomSheet.swift `shouldDismissBottomSheet` drops `sheetHeight * 0.25`, so
    // every sheet closes at 120 pt.
    @Test("a tall sheet needs a quarter of its height")
    func tallSheetNeedsAQuarter() async throws {
        // 740 canvas px tall: a quarter is ~195 pt on screen, so the same 150 pt drag that closes
        // the short sheet springs back here.
        let sdk = try await show("tall_content", title: "Tall Content BottomSheet")
        defer { sdk.tearDown() }
        let resting = try top(sdk, "Tall Content BottomSheet")

        // Grabbed mid-sheet: its title sits right under the status bar.
        let body = try #require(sdk.frame(id: "body"))
        try sdk.drag(from: CGPoint(x: body.midX, y: body.midY), by: CGVector(dx: 0, dy: 150))

        try await sdk.waitUntilSteady(text: "Tall Content BottomSheet")
        #expect(sdk.isShowing("Tall Content BottomSheet"))
        #expect(abs(try top(sdk, "Tall Content BottomSheet") - resting) < 1)
    }

    // Fails if: DigiaBottomSheet.swift `handleDragChange`/`handleDragEnd` lose their
    // `guard config.allowDragDismiss` (or NudgeOverlayView.swift stops passing
    // `surface.draggable` as `allowDragDismiss`).
    @Test("does not move when it is not draggable")
    func lockedSheetDoesNotMove() async throws {
        let sdk = try await show("backdrop_off", title: "Backdrop Tap Dismiss Off")
        defer { sdk.tearDown() }
        let resting = try top(sdk, "Backdrop Tap Dismiss Off")

        let drag = try sdk.drag(
            from: try grab(sdk, "Backdrop Tap Dismiss Off"), by: CGVector(dx: 0, dy: 300), release: false)
        TouchSynthesizer.drainRunLoop(for: 0.1)
        #expect(abs(try top(sdk, "Backdrop Tap Dismiss Off") - resting) < 1, "it does not follow")
        try drag.release()

        try await sdk.settle(0.5)
        #expect(sdk.isShowing("Backdrop Tap Dismiss Off"))
        #expect(abs(try top(sdk, "Backdrop Tap Dismiss Off") - resting) < 1)
    }

    // Fails if: DigiaBottomSheet.swift `handleBackdropTap` stops calling `close()`.
    @Test("closes on a tap outside it when the backdrop dismisses")
    func backdropTapCloses() async throws {
        let sdk = try await show("backdrop_on", title: "Backdrop Tap Dismiss On")
        defer { sdk.tearDown() }

        try sdk.tap(at: CGPoint(x: sdk.screenSize.width / 2, y: 100))

        try await sdk.waitUntil("the sheet is gone") { !sdk.isShowing("Backdrop Tap Dismiss On") }
        #expect(SDKInstance.shared.controller.activeNudge == nil)
    }

    // Fails if: DigiaBottomSheet.swift `handleBackdropTap` loses `if config.allowBackdropDismiss`.
    @Test("stays on a tap outside it when the backdrop is locked")
    func lockedBackdropTapStays() async throws {
        let sdk = try await show("backdrop_off", title: "Backdrop Tap Dismiss Off")
        defer { sdk.tearDown() }

        try sdk.tap(at: CGPoint(x: sdk.screenSize.width / 2, y: 100))

        try await sdk.settle(0.6)
        #expect(sdk.isShowing("Backdrop Tap Dismiss Off"))
        #expect(SDKInstance.shared.controller.activeNudge != nil)
    }

    // Fails if: NudgeOverlayView.swift `NudgeSheetView` stops passing `viewportOverlay` (the
    // outside close button) or its `action: dismiss`.
    @Test("closes from its close button even with a locked backdrop")
    func closeButtonCloses() async throws {
        // The fixture locks its backdrop and is not draggable: the close button is the only way out
        // besides its CTA.
        let sdk = try await show("close_button", title: "Close Button Sheet")
        defer { sdk.tearDown() }

        try await sdk.tapCloseButton()

        try await sdk.waitUntil("the sheet is gone") { !sdk.isShowing("Close Button Sheet") }
        #expect(SDKInstance.shared.controller.activeNudge == nil)
    }

    // Fails if: CanvasNudgeCloseOverlay.swift `outsideClose` drops `placement.margin.left` from its
    // padding, or puts a bottom sheet's outside button below the card (`let top = isBottomSheet ||`).
    @Test("puts a styled close button where it was authored")
    func styledCloseButtonPlacement() async throws {
        // Outside placement, top-left, margin 14 from the left edge.
        let sdk = try await show("close_button_styled", title: "Close Button Sheet")
        defer { sdk.tearDown() }
        try await sdk.waitUntilSteady("the close button settled") { sdk.closeButtonFrame }
        let rect = try #require(sdk.closeButtonFrame)

        #expect(abs(rect.minX - 14) < 0.5, "the authored left margin")
        #expect(rect.maxY <= (try top(sdk, "Close Button Sheet")),
                "outside placement sits above the sheet, not on it")

        // Its far edge still belongs to the button.
        try sdk.tap(at: CGPoint(x: rect.maxX - 3, y: rect.midY))

        try await sdk.waitUntil("the sheet is gone") { !sdk.isShowing("Close Button Sheet") }
    }

    // Flutter shrinks the window to 640 px under a 740 px canvas. The simulator's window cannot be
    // resized, so this holds the same relationship on the real screen: the sheet is at least as
    // tall as the room it has, yet its title sits below the top safe area and its button above the
    // screen's bottom edge.
    // Fails if: NudgeOverlayView.swift `NudgeSheetView` stops fitting the canvas to
    // `availableSize` (the button would be pushed off screen).
    @Test("fits a screen shorter than its canvas, button reachable")
    func tallSheetFitsTheScreen() async throws {
        let sdk = try await show("tall_content", title: "Tall Content BottomSheet")
        defer { sdk.tearDown() }
        let window = try #require(sdk.window)

        let title = try #require(sdk.frame(text: "Tall Content BottomSheet"))
        let button = try #require(sdk.frame(id: "button"))
        #expect(title.minY >= window.safeAreaInsets.top, "below the notch")
        #expect(button.maxY <= sdk.screenSize.height, "on screen")

        try await sdk.tap(id: "button")

        try await sdk.waitUntil("the sheet is gone") { !sdk.isShowing("Tall Content BottomSheet") }
    }
}
}
