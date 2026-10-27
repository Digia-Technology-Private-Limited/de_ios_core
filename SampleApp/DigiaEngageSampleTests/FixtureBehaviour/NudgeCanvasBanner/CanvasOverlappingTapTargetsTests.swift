import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// Which element of an inline canvas receives a tap when children overlap.
/// `canvas/canvas_overlapping_tap_targets` stacks a tap region and a button in three orders; every
/// tap is a real touch on the card the SDK rendered in the app's `DigiaSlot`, and the proof is the
/// URL the host's open-URL handler is asked to open.
///
/// Port of `flutter/core/test/fixture_behaviour/ui_canvas_test.dart`.
@Suite("Canvas: overlapping tap targets", .serialized,
       .tags(.integration, .behaviour, .canvas))
@MainActor
struct CanvasOverlappingTapTargetsTests {

    /// Shows the card and taps the middle of the button authored with [id] (its label is drawn
    /// there), returning every URL the host was asked to open.
    private func tap(_ id: String) async throws -> [String] {
        let campaign = try fixture("canvas/canvas_overlapping_tap_targets")
        let sdk = try await SdkHarness.start(campaign)
        defer { sdk.tearDown() }
        let opened = Received<String>()
        sdk.setOpenURLHandler { opened.append($0) }
        try sdk.mount { DigiaSlot("home_banner") { EmptyView() } }
        try sdk.deliver(keyOf(campaign))

        try await sdk.tap(id: id)

        try await sdk.waitUntil("a URL is opened") { !opened.values.isEmpty }
        try await sdk.settle(0.3) // a second, doubled open would land by now
        #expect(sdk.platform.opened.isEmpty, "the host's handler took it, not iOS")
        return opened.values
    }

    // Fails if: CampaignCanvasModels.swift `isHitTestable` for `.button` returns `true` regardless
    // of `actions` (the action-less button would swallow the touch).
    @Test("a top button with no action lets the region under it take the tap")
    func actionlessButtonPassesTheTap() async throws {
        #expect(try await tap("case1_button") == ["https://digia.com/hit/case1-underlay"])
    }

    // Fails if: CampaignCanvasModels.swift `isHitTestable` for `.button` drops `!actions.isEmpty`
    // (the button would let the touch through to the region under it).
    @Test("a top button with an action wins over the region under it")
    func topButtonWins() async throws {
        #expect(try await tap("case2_button") == ["https://digia.com/hit/case2-button"])
    }

    // Fails if: CampaignCanvasView.swift `CampaignCanvasStage` stops stacking children in authored
    // order (`ForEach(canvas.children)` in a `ZStack`), so the later tap region no longer sits on
    // top of the button.
    @Test("a tap region above a button wins over it")
    func regionAboveWins() async throws {
        #expect(try await tap("case3_button") == ["https://digia.com/hit/case3-underlay"])
    }
}
}
