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
    @Test("floater_story_gradient_window_multipage: a window nobody opens leaves at its 8 s timeout")
    func unopenedWindowLeavesAt8s() async throws {
        let (sdk, presentation) = try await boot("floater_story_gradient_window_multipage")
        defer { sdk.tearDown() }
        let drawnAt = try await sdk.waitForStoryWindow()

        try await sdk.settle(max(0, 7.6 - floaterElapsed(since: drawnAt)))
        #expect(sdk.storyFloater.isShowing, "still inside 8 s")

        try await sdk.waitUntil("the window times out", timeout: 2) { !sdk.storyFloater.isShowing }
        #expect(floaterElapsed(since: drawnAt) < 8.7)
        #expect(presentation.dismissReason == .autoTimeout)
    }

    // Fails if: floater_story_orchestrator.swift `restartAutoDismiss`
    // `UInt64(afterMs) * 1_000_000` -> `UInt64(afterMs) * 2_000_000`.
    @Test("floater_auto_dismiss: a window nobody opens leaves after its 3 s")
    func unopenedWindowLeavesAt3s() async throws {
        let (sdk, presentation) = try await boot("floater_auto_dismiss")
        defer { sdk.tearDown() }
        let drawnAt = try await sdk.waitForStoryWindow()

        try await sdk.settle(max(0, 2.6 - floaterElapsed(since: drawnAt)))
        #expect(sdk.storyFloater.isShowing)

        try await sdk.waitUntil("the window times out", timeout: 2) { !sdk.storyFloater.isShowing }
        #expect(floaterElapsed(since: drawnAt) < 3.7)
        #expect(presentation.dismissReason == .autoTimeout)
    }

    // Fails if: floater_story_orchestrator.swift `onScreenChanged`
    // `if !targets.isEmpty && !targets.contains(screenName) {` -> `if !targets.contains(screenName) {`.
    @Test("floater_story_screen_change_global: a window on every screen survives navigation")
    func globalSurvivesNavigation() async throws {
        let (sdk, presentation) = try await boot("floater_story_screen_change_global", screen: "home")
        defer { sdk.tearDown() }
        try await sdk.waitForStoryWindow()

        sdk.setCurrentScreen("cart")
        sdk.setCurrentScreen("brands")
        try await sdk.settle(0.4)

        #expect(sdk.storyFloater.isShowing)
        #expect(presentation.dismissReason == nil)
    }

    // Fails if: floater_story_orchestrator.swift `onScreenChanged`
    // `if !targets.isEmpty && !targets.contains(screenName) {` -> `if false {`.
    @Test("floater_story_screen_change_home_only: a window for one screen leaves when the app goes elsewhere")
    func homeOnlyLeavesElsewhere() async throws {
        let (sdk, presentation) = try await boot("floater_story_screen_change_home_only", screen: "home")
        defer { sdk.tearDown() }
        try await sdk.waitForStoryWindow()

        sdk.setCurrentScreen("cart")

        try await sdk.waitUntil("the window is gone", timeout: 6) { sdk.storyFloater.state == nil }
        #expect(presentation.dismissReason == .screenExit)
    }
}
}
