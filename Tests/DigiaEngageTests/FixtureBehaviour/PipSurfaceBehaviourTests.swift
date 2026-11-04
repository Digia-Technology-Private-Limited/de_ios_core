import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// What a picture-in-picture window does when nobody touches it: how long it stays, which screens it
/// survives, how big it is drawn, and which chrome it draws. Each test boots the real SDK, delivers the fixture the way a CEP
/// does and lets `DigiaHost` render it. Asserted: the orchestrator's state, the window's rect, and the
/// reason the showing's `CampaignPresentation` settles with. What a person does to the window (taps,
/// drags, swipes) is the sample app's `PipSurfaceBehaviourTests`.
///
/// Fixtures (`sdk_testing_fixtures/campaigns/pip/`): `pip_auto_dismiss`, `pip_video_chrome_pinned_height`,
/// `pip_expand_off_free_drop`, `pip_screen_change_home_only`, `pip_screen_change_global`, `pip_expanded_screen_change_targeted`.
/// Timings run on the wall clock, so each window is asserted inside a band rather than at an instant.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_pip_test.dart`.
@Suite("PiP surface behaviour: time and screens", .serialized, .tags(.integration, .behaviour, .pip, .floater),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct PipSurfaceBehaviourTests {

    private func boot(
        _ json: [String: Any], screen: String? = nil
    ) async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.start(json)
        do {
            let presentation = try sdk.deliverFloater(keyOf(json), screen: screen)
            return (sdk, presentation)
        } catch {
            sdk.tearDown()
            throw error
        }
    }

    private func bootPinned() async throws -> (SdkHarness, CampaignPresentation) {
        try await boot(try fixture("pip/pip_video_chrome_pinned_height"))
    }

    // Fails if: Sources/DigiaEngage/api/internal/campaign/floater_orchestrator.swift
    // `restartAutoDismiss` `UInt64(afterMs) * 1_000_000` -> `UInt64(afterMs) * 2_000_000`.
    @Test("pip_auto_dismiss: leaves after its 3 s timeout, as an auto timeout")
    func autoDismissAfterItsTimeout() async throws {
        let (sdk, presentation) = try await boot(try fixture("pip/pip_auto_dismiss"))
        defer { sdk.tearDown() }
        let drawnAt = try await sdk.waitForPipWindow()

        try await sdk.settle(max(0, 2.6 - floaterElapsed(since: drawnAt)))
        #expect(sdk.pip.isShowing, "still inside 3 s")

        try await sdk.waitUntil("the PiP times out", timeout: 2) { !sdk.pip.isShowing }
        #expect(floaterElapsed(since: drawnAt) < 3.7)
        #expect(presentation.dismissReason == .autoTimeout)
    }

    // Fails if: floater_overlay_view.swift `collapsedRect`
    // `let height = config.collapsed.hasFixedHeight ? config.collapsed.heightDp : width / ratio` ->
    // `let height = false ? config.collapsed.heightDp : width / ratio`.
    @Test("pip_video_chrome_pinned_height: the window is the pinned 240 pt high, not its ratio")
    func pinnedHeight() async throws {
        let (sdk, _) = try await bootPinned()
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        let rect = try sdk.pipRect()
        let screenWidth = try #require(sdk.window).bounds.width

        // 55 % of the screen wide; a 1.78 ratio alone would make it ~120 pt high.
        #expect(rect.height == 240)
        #expect(abs(rect.width - screenWidth * 0.55) < 0.5)
    }

    // Fails if: floater_orchestrator.swift `onScreenChanged`
    // `if !targets.isEmpty && !targets.contains(screenName) {` -> `if false {`.
    @Test("pip_screen_change_home_only: a window targeted at one screen ends when the app leaves it")
    func endsWhenItsScreenIsLeft() async throws {
        let (sdk, presentation) = try await boot(try fixture("pip/pip_screen_change_home_only"), screen: "home")
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()

        sdk.setCurrentScreen("cart")

        try await sdk.waitUntil("the PiP is gone", timeout: 6) { sdk.pip.state == nil }
        #expect(presentation.dismissReason == .screenExit)
    }

    // Fails if: floater_orchestrator.swift `onScreenChanged`
    // `if !targets.isEmpty && !targets.contains(screenName) {` -> `if !targets.contains(screenName) {`.
    @Test("pip_screen_change_global: a window on every screen survives navigation")
    func globalSurvivesNavigation() async throws {
        let (sdk, presentation) = try await boot(try fixture("pip/pip_screen_change_global"), screen: "home")
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()

        sdk.setCurrentScreen("cart")
        sdk.setCurrentScreen("brands")
        try await sdk.settle(1)

        #expect(sdk.pip.isShowing)
        #expect(presentation.dismissReason == nil)
    }

    // Fails if: floater_orchestrator.swift `onScreenChanged`
    // `if !targets.isEmpty && !targets.contains(screenName) {` -> `if false {`.
    @Test("pip_expanded_screen_change_targeted: full screen stays across the screens it targets and ends on any other")
    func expandedEndsOffItsScreens() async throws {
        let (sdk, presentation) = try await boot(
            try fixture("pip/pip_expanded_screen_change_targeted"), screen: "home")
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        #expect(sdk.pip.surface == .expanded)

        sdk.setCurrentScreen("brands")
        try await sdk.settle(1)
        #expect(sdk.pip.isShowing, "brands is one of its screens")

        sdk.setCurrentScreen("cart")
        try await sdk.waitUntil("the PiP is gone", timeout: 6) { sdk.pip.state == nil }
        #expect(presentation.dismissReason == .screenExit, "cart is not, even from full screen")
    }

    // Fails if: floater_overlay_view.swift `if config.controls.showExpand, config.behavior.tapExpands {`
    // -> `if config.controls.showExpand {`.
    @Test("pip_expand_off_free_drop: no expand pill is drawn when the author turned expanding off")
    func noExpandPillWhenExpandingIsOff() async throws {
        let (sdk, _) = try await boot(try fixture("pip/pip_expand_off_free_drop"))
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        let rect = try sdk.pipRect()

        let bottomLeft = CGRect(x: rect.minX, y: rect.midY, width: rect.width / 2, height: rect.height / 2)
        #expect(try sdk.floaterButtons(in: bottomLeft).isEmpty, "showExpand is on, but there is nothing to expand to")
        #expect(try !sdk.floaterButtons(in: rect).isEmpty, "the × is still there")
    }
}
}
