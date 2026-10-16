import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `openDeeplink`: authored as `Action.openUrl` with `launchMode: platformDefault`, which the SDK
/// reads as a deep link, on the `canvas-button-fill` card.
///
/// iOS has no launch-mode distinction (see `OpenUrlActionTests`): a deep link with no app handler
/// ends in the same `UIApplication.open(url)` as an external URL. What differs is the route — this
/// one would go to the app's `deepLink` handler — so this pins the URL handed to iOS.
@Suite("OpenDeeplink action", .serialized, .tags(.actions, .integration))
@MainActor
struct OpenDeeplinkActionTests {

    @Test("tapping a button authored as a deep link hands it to iOS")
    func deepLinkOpensTheAuthoredLink() async throws {
        let sdk = try await ActionHarness.start(ActionCampaigns.button(steps: [
            ["type": "Action.openUrl",
             "data": ["url": "digia-test://campaign-lab", "launchMode": "platformDefault"]],
        ]))
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(ActionHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver(ActionHarness.buttonCampaignKey)

        try await sdk.tap(id: ActionHarness.buttonId)

        try await sdk.waitUntil("the link is opened") { !sdk.platform.opened.isEmpty }
        #expect(sdk.platform.opened == ["digia-test://campaign-lab"])
    }
}
}
