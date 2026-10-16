import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `copyToClipBoard`: the boundary is the system pasteboard.
@Suite("CopyToClipboard action", .serialized, .tags(.actions, .integration))
@MainActor
struct CopyToClipboardActionTests {

    @Test("tapping a button authored with copyToClipBoard puts its text on the pasteboard")
    func copyPutsTextOnThePasteboard() async throws {
        let sdk = try await ActionHarness.start(ActionCampaigns.button(steps: [
            ["type": "Action.copyToClipBoard", "data": ["message": "SAVE20"]],
        ]))
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(ActionHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver(ActionHarness.buttonCampaignKey)

        try await sdk.tap(id: ActionHarness.buttonId)

        try await sdk.waitUntil("the text is copied") { !sdk.platform.copied.isEmpty }
        #expect(sdk.platform.copied == ["SAVE20"])
    }
}
}
