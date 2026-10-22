// tags: action
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// `Action.copyToClipboard`: the boundary is the system pasteboard.
@MainActor
@Suite("copy_to_clipboard action", .serialized)
struct CopyToClipboardActionTests {
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
