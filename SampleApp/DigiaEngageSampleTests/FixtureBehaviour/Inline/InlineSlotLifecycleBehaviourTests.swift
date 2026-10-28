import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// How an inline slot is emptied, driven from the shared fixtures `inline_canvas/inline_canvas_home`
/// and `inline_canvas/inline_canvas_bg_dark`, which both target the slot `home_banner`.
///
/// A fixture is served by the mocked bundle, delivered the way a CEP does and drawn by the app's
/// own `DigiaSlot`. A slot loses its campaign three ways: another campaign takes it, the CEP
/// cancels its delivery, or the host clears the slot (on logout). Each time the campaign that was
/// in it is told it is over, so the CEP can free its hold. The proof is what is on screen, what the
/// slot holds, and the outcome the CEP's delivery ends with.
///
/// Port of `flutter/core/test/fixture_behaviour/ui_inline_slot_lifecycle_test.dart`.
@Suite("Inline slot lifecycle", .serialized, .tags(.integration, .behaviour, .inline))
@MainActor
struct InlineSlotLifecycleBehaviourTests {

    private static let slot = "home_banner"
    /// The only text either card draws; `inline_canvas_home` is all pictures.
    private static let darkTitle = "Premium Health Pass"

    private func showSlot() async throws -> (SdkHarness, first: [String: Any], second: [String: Any]) {
        let first = try fixture("inline_canvas/inline_canvas_home")
        let second = try fixture("inline_canvas/inline_canvas_bg_dark")
        let sdk = try await SdkHarness.start(campaigns: [first, second])
        _ = try sdk.mountInlineSlot(Self.slot)
        return (sdk, first, second)
    }

    private func holder(_ sdk: SdkHarness) -> String? {
        sdk.sdk.inlineController.getCampaign(Self.slot)?.campaignKey
    }

    @Test("a second campaign for a slot that is taken is turned away, and the first stays")
    func secondCampaignIsTurnedAway() async throws {
        let (sdk, first, second) = try await showSlot()
        defer { sdk.tearDown() }
        let one = try sdk.deliver(keyOf(first))
        try await sdk.waitUntil("the first card is displayed") { one.state == .displaying }

        let two = try sdk.deliver(keyOf(second))
        try await sdk.settle()

        #expect(!sdk.isShowing(Self.darkTitle))
        #expect(two.dropReason == .surfaceBusy)
        #expect(holder(sdk) == keyOf(first))
        #expect(one.outcome.settledValue == nil, "the first is still on screen")
    }

    // Fails if: Sources/DigiaEngage/api/internal/SDKInstance.swift:934
    // `inlineController.removeCampaign(campaignID)` -> `(deleted)`
    @Test("cancelling a delivery takes its campaign out of the slot and settles it as dismissed")
    func cancellingEmptiesTheSlot() async throws {
        let (sdk, _, second) = try await showSlot()
        defer { sdk.tearDown() }
        let one = try sdk.deliver(keyOf(second))
        try await sdk.waitUntil("the card is displayed") { one.state == .displaying && sdk.isShowing(Self.darkTitle) }

        one.cancel()

        try await sdk.waitUntil("the card is gone") { !sdk.isShowing(Self.darkTitle) }
        #expect(holder(sdk) == nil)
        // The slot tells the CEP its campaign is over before the cancel settles it, so the outcome
        // the CEP sees is the dismissal's.
        try await sdk.waitUntil("the delivery settles") { one.outcome.isSettled }
        #expect(one.dismissReason != nil, "settled as \(String(describing: one.outcome.settledValue))")
    }

    @Test("cancelling a delivery that holds no slot changes nothing")
    func cancellingAnotherDeliveryChangesNothing() async throws {
        let (sdk, _, second) = try await showSlot()
        defer { sdk.tearDown() }
        let one = try sdk.deliver(keyOf(second))
        try await sdk.waitUntil("the card is displayed") { one.state == .displaying && sdk.isShowing(Self.darkTitle) }
        // A campaign key the bundle does not have never fills the slot.
        let other = try sdk.deliver("not_in_the_bundle")

        other.cancel()
        try await sdk.settle()

        #expect(sdk.isShowing(Self.darkTitle))
        #expect(holder(sdk) == keyOf(second))
        #expect(one.outcome.settledValue == nil)
    }

    // Fails if: Sources/DigiaEngage/api/internal/InlineCampaignController.swift:113
    // `if let removed { notifyRemovedCampaigns([removed], reason: reason) }` -> `(deleted)`
    @Test("the host clearing the slot, as on logout, empties it and settles the campaign in it")
    func hostClearingEmptiesTheSlot() async throws {
        let (sdk, _, second) = try await showSlot()
        defer { sdk.tearDown() }
        let one = try sdk.deliver(keyOf(second))
        try await sdk.waitUntil("the card is displayed") { one.state == .displaying && sdk.isShowing(Self.darkTitle) }

        Digia.clearInlineContent(Self.slot)

        try await sdk.waitUntil("the card is gone") { !sdk.isShowing(Self.darkTitle) }
        #expect(holder(sdk) == nil)
        try await sdk.waitUntil("the delivery settles") { one.outcome.isSettled }
        #expect(one.dismissReason != nil, "settled as \(String(describing: one.outcome.settledValue))")
    }

    @Test("clearing a slot that holds nothing is harmless")
    func clearingAnotherSlotIsHarmless() async throws {
        let (sdk, _, second) = try await showSlot()
        defer { sdk.tearDown() }
        let one = try sdk.deliver(keyOf(second))
        try await sdk.waitUntil("the card is displayed") { one.state == .displaying && sdk.isShowing(Self.darkTitle) }

        Digia.clearInlineContent("some_other_slot")
        try await sdk.settle()

        #expect(sdk.isShowing(Self.darkTitle))
        #expect(one.outcome.settledValue == nil)
    }
}
}
