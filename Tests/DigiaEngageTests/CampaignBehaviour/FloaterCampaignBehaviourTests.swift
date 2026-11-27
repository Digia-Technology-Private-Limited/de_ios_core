// tags: widget floater pip campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension RenderedUITests {
/// Every way a PiP or story floater ends and the exact chain it sends. Both float over the app, so the CEP's
/// hold comes back at the impression while they keep running. The cases that need a real touch run hosted, in
/// `SampleApp/DigiaEngageSampleTests/CampaignBehaviour/FloaterCampaignBehaviourTests.swift`.
///
/// The chrome's glyph buttons carry no accessibility label, so a test tells them apart by the fixed corner
/// each sits in; the touch on them is still a real one.
///
/// platform note: the Dart twin is `test/campaign_behaviour/floating_campaign_behaviour_test.dart`.
@MainActor
@Suite("Floater campaign behaviour", .serialized, .tags(.integration, .floater, .pip, .analytics))
struct FloaterCampaignBehaviourTests {
    private func fixture(_ path: String) -> WorkspaceFixtures.Campaign { WorkspaceFixtures.campaign(path) }

    private func start(_ path: String) async throws -> SdkHarness {
        try await SdkHarness.startChain([fixture(path)]) { Text("App home") }
    }

    /// Waits for the floater's impression: a PiP shows only once its media has loaded.
    private func show(_ sdk: SdkHarness, _ d: Delivery) async throws {
        try await sdk.waitUntil("the floater's impression", timeout: 5) { d.displayed }
        try await sdk.settle(1)
    }

    // MARK: - PiP

    // MARK: - Story floater

    // MARK: - Dropped

    // As coded: the image answers 404, so the PiP has no media to float; its window never opens, and the media
    // end it reports reaches the CEP as a cancel (`cancelled`), with the media end as the cause.
}
}
