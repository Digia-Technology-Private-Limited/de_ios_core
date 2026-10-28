import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `openDeeplink`: the `actions/fixtures/action_open_deeplink` card, whose button is authored
/// `Action.openUrl` with `launchMode: platformDefault`, which the SDK reads as a deep link.
///
/// iOS has no launch-mode distinction (see `OpenUrlActionTests`): a deep link with no app handler
/// ends in the same `UIApplication.open(url)` as an external URL. What differs is the route — this
/// one would go to the app's `deepLink` handler — so this pins the URL handed to iOS.
@Suite("OpenDeeplink action", .serialized, .tags(.actions, .integration))
@MainActor
struct OpenDeeplinkActionTests {

    @Test("tapping a button authored as a deep link hands it to iOS")
    func deepLinkOpensTheAuthoredLink() async throws {
        let sdk = try await SdkHarness.start(
            loadCampaign("actions/action_open_deeplink.json"))
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(SdkHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver("test_action_open_deeplink")

        try await sdk.tap(id: SdkHarness.buttonId)

        try await sdk.waitUntil("the link is opened") { !sdk.platform.opened.isEmpty }
        #expect(sdk.platform.opened == ["digia-test://deeplink-screen"])
    }
}
}
