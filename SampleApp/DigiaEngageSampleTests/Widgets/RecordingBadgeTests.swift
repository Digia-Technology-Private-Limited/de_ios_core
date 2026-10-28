import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// The floating "Digia" debug bubble (`RecordingBadgeView`), mounted by `DigiaHost` over the app:
/// when it shows, what a tap on it opens, and where a drag leaves it. Real touches throughout.
///
/// Port of `flutter/core/test/digia_recording_badge_test.dart`, plus iOS's
/// `Digia.presentDebugSettings` / `handleDeepLink` (the counterpart of
/// `flutter/core/test/debug_settings_deeplink_observer_test.dart`'s open/leave-to-host cases;
/// the URL matching itself is `DigiaDebugSettingsDeepLinkTests`). The live-test dot has no
/// accessibility of its own, so its presence is read from the bubble's width.
@Suite("Debug bubble", .serialized, .tags(.integration, .debug))
@MainActor
struct RecordingBadgeTests {

    private var overlay: DigiaDebugOverlayController { SDKInstance.shared.debugOverlayControllerSnapshot() }

    private func showsBubble(_ sdk: SdkHarness) -> Bool {
        sdk.widgetsIsShowing(exactly: "Digia") && Digia.debugBadgeFrame != nil
    }

    // Fails if: RecordingBadgeView.swift stops gating on `overlay.isVisible`, or
    // `DraggableBadge.onDisappear` stops clearing `badgeFrame`.
    @Test("hidden while the bubble is off, shown once it is turned on, and hidden again once off")
    func followsTheSetting() async throws {
        let sdk = try await SdkHarness.widgetsBoot()
        defer { sdk.widgetsFinish() }
        try await sdk.settle(0.3)
        #expect(!showsBubble(sdk))

        overlay.setVisible(true)
        try await sdk.waitUntil("the bubble") { showsBubble(sdk) }

        overlay.setVisible(false)
        try await sdk.waitUntil("the bubble gone") { !sdk.widgetsIsShowing(exactly: "Digia") }
        try await sdk.waitUntil("its frame cleared") { Digia.debugBadgeFrame == nil }
    }

    // Fails if: ComponentRegistryService.swift `setEnabled` stops turning the bubble on.
    @Test("turning Sync on shows the bubble automatically")
    func syncShowsTheBubble() async throws {
        let sdk = try await SdkHarness.widgetsBoot()
        defer { sdk.widgetsFinish() }

        SDKInstance.shared.componentRegistrySnapshot().setEnabled(true)

        try await sdk.waitUntil("the bubble") { showsBubble(sdk) }
        #expect(overlay.isVisible)
    }

    // Fails if: RecordingBadgeView.swift `BadgeContent.dotColor` returns nil for `.connecting`
    // (no dot while the stream is retrying).
    @Test("shows the connection dot once live testing is connecting, and none while disconnected")
    func showsTheConnectionDot() async throws {
        let sdk = try await SdkHarness.widgetsBoot()
        defer { sdk.widgetsFinish() }
        overlay.setVisible(true)
        try await sdk.waitUntil("the bubble") { showsBubble(sdk) }
        try await sdk.settle(0.3)
        let bare = try #require(Digia.debugBadgeFrame).width

        SDKInstance.shared.liveTestServiceSnapshot().setEnabled(true)

        try await sdk.waitUntil("connecting") { SDKInstance.shared.liveTestServiceSnapshot().connectionState == .connecting }
        // An 8 pt dot after a 6 pt gap.
        try await sdk.waitUntil("the bubble widens by the dot") {
            (Digia.debugBadgeFrame?.width ?? 0) >= bare + 13
        }
    }

    // Fails if: RecordingBadgeView.swift's `onSettings: { presentDebugSettings() }` is dropped, or
    // `DraggableBadge.presentDebugSettings` stops presenting from
    // `ViewControllerUtil.topViewController()`. (digia.swift's already-open guard only spares a
    // UIKit warning: without it UIKit refuses the second presentation itself, so the one screen
    // stays either way.)
    @Test("tapping the bubble opens the debug settings, and opening them again keeps the one screen")
    func tapOpensSettingsOnce() async throws {
        let sdk = try await SdkHarness.widgetsBoot()
        defer { sdk.widgetsFinish() }
        overlay.setVisible(true)

        try await sdk.widgetsTap(exactly: "Digia") { sdk.widgetsSettingsScreen != nil }
        let screen = try #require(sdk.widgetsSettingsScreen)
        try await sdk.waitUntil("the settings on screen") { sdk.isShowing("Digia bubble") }

        let root = try #require(sdk.window?.rootViewController)
        Digia.presentDebugSettings(from: root)
        #expect(Digia.handleDeepLink(URL(string: "myapp://_digia/debug-settings")!, from: root))
        try await sdk.settle(0.5)
        #expect(sdk.presentedViewer === screen)
        #expect(screen.presentedViewController == nil, "nothing stacked on top of it")
    }

    // Fails if: digia.swift `handleDeepLink` stops returning false for a link that is not its own,
    // or presents for it.
    @Test("a deep link that is not the debug link is left to the app, and one that is opens the settings")
    func deepLinkRouting() async throws {
        let sdk = try await SdkHarness.widgetsBoot()
        defer { sdk.widgetsFinish() }
        let root = try #require(sdk.window?.rootViewController)

        #expect(!Digia.handleDeepLink(URL(string: "myapp://checkout")!, from: root))
        try await sdk.settle(0.5)
        #expect(sdk.presentedViewer == nil)

        #expect(Digia.handleDeepLink(URL(string: "/tabs/_digia/debug-settings")!, from: root))
        try await sdk.waitUntil("the settings") { sdk.widgetsSettingsScreen != nil }
    }

    // Fails if: RecordingBadgeView.swift's drag `onEnded` stops snapping to the nearer edge
    // (`leading ? Self.margin : proxy.size.width - badgeSize.width - Self.margin`), or `onChanged`
    // stops following the finger vertically.
    @Test("a dragged bubble follows the finger down and snaps to the nearer side on release")
    func dragSnapsToNearerEdge() async throws {
        let sdk = try await SdkHarness.widgetsBoot()
        defer { sdk.widgetsFinish() }
        let window = try #require(sdk.window)
        overlay.setVisible(true)
        let start = try await sdk.widgetsSteadyFrame("the bubble") { Digia.debugBadgeFrame }
        #expect(abs(start.minX - 8) <= 1, "starts on the leading edge")

        // Released right of centre: snaps to the trailing edge.
        try WidgetsBadgeDrag.drag(
            from: CGPoint(x: start.midX, y: start.midY), by: CGVector(dx: window.bounds.width * 0.6, dy: 200),
            in: window, duration: 0.4, hold: 0.3)
        let right = try await sdk.widgetsSteadyFrame("the bubble after the drag") { Digia.debugBadgeFrame }
        #expect(abs(right.maxX - (window.bounds.width - 8)) <= 1)
        #expect(abs(right.minY - (start.minY + 200)) <= 2)

        // A short drag that ends still right of centre goes back to the trailing edge.
        try WidgetsBadgeDrag.drag(
            from: CGPoint(x: right.midX, y: right.midY), by: CGVector(dx: -40, dy: 0),
            in: window, duration: 0.3, hold: 0.3)
        let stillRight = try await sdk.widgetsSteadyFrame("the bubble after a short drag") { Digia.debugBadgeFrame }
        #expect(abs(stillRight.maxX - (window.bounds.width - 8)) <= 1)

        // Released left of centre: back on the leading edge, at the height it was dropped.
        try WidgetsBadgeDrag.drag(
            from: CGPoint(x: stillRight.midX, y: stillRight.midY), by: CGVector(dx: -window.bounds.width * 0.6, dy: -100),
            in: window, duration: 0.4, hold: 0.3)
        let left = try await sdk.widgetsSteadyFrame("the bubble back") { Digia.debugBadgeFrame }
        #expect(abs(left.minX - 8) <= 1)
        #expect(abs(left.minY - (stillRight.minY - 100)) <= 2)
    }

    // Fails if: RecordingBadgeView.swift's drag `onChanged` stops clamping the bubble inside the
    // safe area (`max(minY, …)`).
    @Test("a bubble dragged off the top stays below the status bar")
    func dragIsClampedToSafeArea() async throws {
        let sdk = try await SdkHarness.widgetsBoot()
        defer { sdk.widgetsFinish() }
        let window = try #require(sdk.window)
        overlay.setVisible(true)
        let start = try await sdk.widgetsSteadyFrame("the bubble") { Digia.debugBadgeFrame }

        try WidgetsBadgeDrag.drag(
            from: CGPoint(x: start.midX, y: start.midY), by: CGVector(dx: 0, dy: -start.minY - 200),
            in: window, duration: 0.4, hold: 0.3)

        let top = try await sdk.widgetsSteadyFrame("the bubble after the drag") { Digia.debugBadgeFrame }
        #expect(top.minY >= window.safeAreaInsets.top - 1)
        #expect(top.minY < start.minY)
    }
}
}
