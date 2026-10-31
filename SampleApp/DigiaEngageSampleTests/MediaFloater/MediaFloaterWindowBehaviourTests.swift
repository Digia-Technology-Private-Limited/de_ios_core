import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// The floater window parts the surface ports in `FixtureBehaviour/Floater/` do not reach: moving a
/// story floater's window with a real drag, the PiP's expand pill, and a CTA in
/// the expanded PiP. Each test boots the real SDK, delivers a shared fixture the way a CEP does and
/// lets `DigiaHost` render it; touches are real (`TouchSynthesizer`).
///
/// Fixtures: `floater/floater_story_window` (bottom-right story window; `controls` set on the loaded
/// copy), `pip/pip_video_chrome_pinned_height` (expand pill), `pip/pip_expanded_canvas_cta` (an
/// `Action.openUrl` CTA on the expanded canvas). That `pip_expand_off_free_drop` draws no expand pill is
/// checked untouched, in the package's `FixtureBehaviour/PipSurfaceBehaviourTests.swift`.
///
/// Flutter's `surface_floater_test.dart` has no drag or entry-animation case for the story window;
/// these follow its PiP counterparts in `flutter/core/test/fixture_behaviour/surface_pip_test.dart`
/// (`a drag past the middle snaps to the opposite edge`, `with snapping off, a drop stays where it
/// was let go`), which `FixtureBehaviour/Floater/PipSurfaceBehaviourTests.swift` already ports
/// for the PiP. The window's fly-in entry is not tested: its offset is SwiftUI render-side
/// animation state that neither the published `activeRect` nor a `drawHierarchy` snapshot exposes
/// mid-flight (both read the landed position).
@Suite("Media floater: window behaviour", .serialized,
       .tags(.integration, .behaviour, .floater, .pip),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct MediaFloaterWindowBehaviourTests {

    private func boot(
        _ json: [String: Any], screen: String? = nil
    ) async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.start(json)
        do {
            return (sdk, try sdk.deliverFloater(keyOf(json), screen: screen))
        } catch {
            sdk.tearDown()
            throw error
        }
    }

    /// The tracked events of [key], read again until one matches [match] (a flush is sent
    /// asynchronously, so a single read can come too early) or five seconds pass.
    private func events(
        _ sdk: SdkHarness, _ key: String, until match: ([String: Any]) -> Bool
    ) async throws -> [[String: Any]] {
        var events: [[String: Any]] = []
        for _ in 0..<10 {
            events = try await sdk.events().filter { $0["campaign_key"] as? String == key }
            if events.contains(where: match) { break }
            try await sdk.settle(0.2)
        }
        return events
    }

    /// The `FloaterEvent.Dismissed` this test's showing of [key] reported.
    private func dismissedEvent(_ sdk: SdkHarness, _ key: String) async throws -> [String: Any] {
        let isDismissed: ([String: Any]) -> Bool = { ($0["event_name"] as? String)?.contains("Dismissed") == true }
        let events = try await events(sdk, key, until: isDismissed)
        return try #require(events.last(where: isDismissed),
                            "no dismissed event in \(events.compactMap { $0["event_name"] })")
    }

    private func properties(_ event: [String: Any]) -> [String: Any] {
        event["properties"] as? [String: Any] ?? event
    }

    // MARK: - Story window drag

    // Fails if: Sources/DigiaEngage/api/widgets/floater_story_overlay_view.swift `handleDragEnded`
    // `fx = projectedFx >= 0.5 ? 1 : 0` -> `fx = 1`.
    // Fails if: floater_story_overlay_view.swift `handleDragEnded` `orchestrator.moveTo(FloaterFraction(x: fx, y: fy))`
    // is deleted (the window springs back and the move is never counted).
    @Test("floater_story_window: a drag past the middle snaps the window to the opposite corner, and the move is reported")
    func storyWindowDragSnapsAcross() async throws {
        let json = try fixture("floater/floater_story_window")
        let (sdk, _) = try await boot(json)
        defer { sdk.tearDown() }
        try await sdk.waitForStoryWindow()
        let before = try #require(sdk.storyFloater.activeRect)

        try TouchSynthesizer.drag(
            from: CGPoint(x: before.midX, y: before.midY), by: CGVector(dx: -250, dy: 0),
            in: try #require(sdk.window), duration: 0.5, hold: 0.3)
        try await sdk.waitUntil("the drop is recorded", timeout: 6) { sdk.storyFloater.dragFraction != nil }

        #expect(sdk.storyFloater.dragFraction == FloaterFraction(x: 0, y: 1))
        #expect(sdk.storyFloater.restingCorner() == .bottomLeft)
        #expect(!sdk.storyFloater.storyOpen, "dragging is not a tap")
        try await sdk.waitUntil("the window settles at the left edge", timeout: 6) {
            (sdk.storyFloater.activeRect?.minX ?? .infinity) < before.minX - 150
        }

        sdk.storyFloater.dismiss(.userClose)
        let dismissed = properties(try await dismissedEvent(sdk, keyOf(json)))
        #expect(dismissed["moves"] as? Int == 1)
        #expect(dismissed["last_position"] as? String == "bottom_left")
        #expect(dismissed["expands"] as? Int == 0)
    }

    // Fails if: floater_story_overlay_view.swift `handleDragEnded` `if config.controls.snapToCorner {`
    // -> `if true {`.
    @Test("floater_story_window: with snapping off, a drop stays where it was let go")
    func storyWindowFreeDropStays() async throws {
        let json = try floaterFixture(
            "floater/floater_story_window", setting: [(["controls", "snapToEdge"], false)])
        let (sdk, _) = try await boot(json)
        defer { sdk.tearDown() }
        try await sdk.waitForStoryWindow()
        let before = try #require(sdk.storyFloater.activeRect)

        try TouchSynthesizer.drag(
            from: CGPoint(x: before.midX, y: before.midY), by: CGVector(dx: -100, dy: -200),
            in: try #require(sdk.window), duration: 0.5, hold: 0.3)
        try await sdk.waitUntil("the drop is recorded", timeout: 6) { sdk.storyFloater.dragFraction != nil }

        let fraction = try #require(sdk.storyFloater.dragFraction)
        #expect(fraction.x > 0 && fraction.x < 1, "x \(fraction.x)")
        #expect(fraction.y > 0 && fraction.y < 1, "y \(fraction.y)")
        try await sdk.settle(0.6)
        let after = try #require(sdk.storyFloater.activeRect)
        #expect(abs(after.midX - (before.midX - 100)) < 12, "left where it was let go: \(after) from \(before)")
        #expect(abs(after.midY - (before.midY - 200)) < 12, "left where it was let go: \(after) from \(before)")
    }

    // MARK: - PiP expand pill

    // Fails if: Sources/DigiaEngage/api/widgets/floater_overlay_view.swift the collapsed chrome's
    // expand pill `orchestrator.expand()` is deleted.
    @Test("pip_video_chrome_pinned_height: the expand pill opens full screen and is reported as pip_expand")
    func expandPillOpensFullScreen() async throws {
        let json = try floaterFixture(
            "pip/pip_video_chrome_pinned_height", setting: [(["behavior", "autoDismissAfterMs"], 86_400_000)])
        let (sdk, _) = try await boot(json)
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        let rect = try sdk.pipRect()

        try sdk.tapFloater(at: try sdk.floaterButton(in: rect, nearest: CGPoint(x: rect.minX, y: rect.maxY)))
        try await sdk.waitUntil("full screen", timeout: 6) { sdk.pip.surface == .expanded }

        let clicks = try await events(sdk, keyOf(json)) { self.properties($0)["element_id"] as? String == "pip_expand" }
            .map(properties)
            .compactMap { $0["element_id"] as? String }
        #expect(clicks.contains("pip_expand"), "\(clicks)")
        #expect(!clicks.contains("pip_media"), "the pill, not the window behind it, took the tap")
    }

    // MARK: - Expanded PiP CTA

    // Fails if: floater_overlay_view.swift `performFloaterCanvasAction`
    // `SDKInstance.shared.onFloaterActionCompleted()` is deleted (the PiP stays up after its CTA ran).
    @Test("pip_expanded_canvas_cta: the expanded CTA runs its action and ends the showing as the CTA taken")
    func expandedCtaRunsAndEnds() async throws {
        let json = try floaterFixture(
            "pip/pip_expanded_canvas_cta", setting: [(["behavior", "autoDismissAfterMs"], 86_400_000)])
        let (sdk, presentation) = try await boot(json)
        defer { sdk.tearDown() }
        try await sdk.waitForPipWindow()
        try sdk.tapFloaterWindow()
        try await sdk.waitUntil("full screen", timeout: 6) { sdk.pip.surface == .expanded }
        try await sdk.settle(0.6)

        try await sdk.tap(id: "pip_cta_button")

        try await sdk.waitUntil("the showing ends", timeout: 6) { !sdk.pip.isShowing }
        #expect(sdk.platform.opened == ["medihub://shop/listing?category=wellness"])
        #expect(presentation.dismissReason == .ctaAction)
        let events = try await events(sdk, keyOf(json)) { self.properties($0)["cta_label"] as? String == "Claim Deal Now" }
        let stepClick = events.map(properties).first { $0["cta_label"] as? String == "Claim Deal Now" }
        #expect(stepClick != nil, "\(events.compactMap { $0["event_name"] })")
    }
}
}
