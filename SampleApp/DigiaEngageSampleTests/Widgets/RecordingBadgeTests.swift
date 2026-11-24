import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// The floating "Digia" debug bubble (`RecordingBadgeView`), mounted by `DigiaHost` over the app:
/// the live-test connection dot. Real touches throughout. Bubble visibility,
/// taps, link routing and drag snaps moved to the shared YAML suite
/// (`tests/debug/`, category issue #239).
@Suite("Debug bubble", .serialized, .tags(.integration, .debug))
@MainActor
struct RecordingBadgeTests {

    private var overlay: DigiaDebugOverlayController { SDKInstance.shared.debugOverlayControllerSnapshot() }

    private func showsBubble(_ sdk: SdkHarness) -> Bool {
        sdk.widgetsIsShowing(exactly: "Digia") && Digia.debugBadgeFrame != nil
    }

    // The drag snaps moved to the shared YAML suite
    // (`tests/debug/debug_bubble_drag.yaml`), which drags the real bubble on
    // every stack and locks each stack's resting edges in goldens.
    // not converted: the dot shows on the bubble over the app, and the
    // settings cannot be closed on iOS (no back command), so YAML can never
    // photograph it there. The live-test dot has no accessibility of its own,
    // so its presence is read from the bubble's width.
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
}
}
