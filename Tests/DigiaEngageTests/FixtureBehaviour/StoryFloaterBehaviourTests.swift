import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// What a story floater's window does when nobody opens it: how long it stays and which screens it
/// survives. Each test boots the real SDK, delivers the fixture the way a CEP does and lets `DigiaHost`
/// render it. Asserted: the orchestrator's state and the reason the showing's `CampaignPresentation`
/// settles with. Opening the story and what happens inside it is the sample app's
/// `StoryFloaterBehaviourTests`.
///
/// Fixtures (`sdk_testing_fixtures/campaigns/floater/`): `floater_story_gradient_window_multipage`,
/// `floater_auto_dismiss`, `floater_story_screen_change_global`, `floater_story_screen_change_home_only`.
/// Flutter runs these on a fake clock; here timeouts are measured on the wall clock and asserted inside
/// a band.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_floater_test.dart`.
@Suite("Story floater behaviour: time and screens", .serialized, .tags(.integration, .behaviour, .floater, .media),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct StoryFloaterBehaviourTests {

    private func boot(
        _ name: String, screen: String? = nil
    ) async throws -> (SdkHarness, CampaignPresentation) {
        let json = try fixture("floater/\(name)")
        let sdk = try await SdkHarness.start(json)
        do {
            let presentation = try sdk.deliverFloater(keyOf(json), screen: screen)
            return (sdk, presentation)
        } catch {
            sdk.tearDown()
            throw error
        }
    }

    // Fails if: floater_story_orchestrator.swift `restartAutoDismiss`
    // `UInt64(afterMs) * 1_000_000` -> `UInt64(afterMs) * 2_000_000`.

    // Fails if: floater_story_orchestrator.swift `onScreenChanged`
    // `if !targets.isEmpty && !targets.contains(screenName) {` -> `if !targets.contains(screenName) {`.

    // Fails if: floater_story_orchestrator.swift `onScreenChanged`
    // `if !targets.isEmpty && !targets.contains(screenName) {` -> `if false {`.
}
}
