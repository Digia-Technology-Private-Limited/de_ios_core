// tags: action
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension HostedUITests {
    /// `copyToClipBoard`: the `actions/fixtures/action_copy_to_clipboard` card, whose button copies
    /// "SAVE20". The boundary is the system pasteboard.
    @Suite("CopyToClipboard action", .serialized, .tags(.actions, .integration))
    @MainActor
    struct CopyToClipboardActionTests {

        @Test("tapping a button authored with copyToClipBoard puts its text on the pasteboard")
        func copyPutsTextOnThePasteboard() async throws {
            let sdk = try await SdkHarness.start(
                loadCampaign("actions/action_copy_to_clipboard.json"))
            defer { sdk.tearDown() }
            try sdk.mount { DigiaSlot(SdkHarness.buttonSlotKey) { EmptyView() } }
            try sdk.deliver("test_action_copy_to_clipboard")

            try await sdk.tap(id: SdkHarness.buttonId)

            try await sdk.waitUntil("the text is copied") { !sdk.platform.copied.isEmpty }
            #expect(sdk.platform.copied == ["SAVE20"])
        }
    }
}

/// `Action.copyToClipboard`: the boundary is the system pasteboard.
@MainActor
@Suite("copy_to_clipboard action (workspace fixture)", .serialized)
struct CopyToClipboardWorkspaceFixtureTests {
    // Fails if `GlobalActionExecutor.execute` stops sending `.copyToClipboard` text to its `copy` closure.
    @Test("tapping a button authored with copyToClipBoard puts its text on the pasteboard")
    func copiesText() async throws {
        let campaign = WorkspaceFixtures.campaign("actions/action_copy_to_clipboard.json")
        let sdk = try await SdkHarness.start([campaign]) {
            DigiaSlot("home_banner") { Color.clear }
        }
        defer { sdk.tearDown() }
        sdk.cep.deliver(campaign.campaignKey)
        await sdk.settle()
        UIPasteboard.general.string = ""

        try await sdk.tap(text: "Confirm & Claim")

        #expect(UIPasteboard.general.string == "SAVE20")
    }
}
