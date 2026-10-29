import Testing
import UIKit
@testable import DigiaEngage

/// The real touches the PiP and story-floater behaviour suites send, on top of the touch-free helpers
/// in `Tests/DigiaEngageTests/FixtureBehaviour/FloaterBehaviourSupport.swift`.
extension SdkHarness {

    /// Taps the collapsed PiP or story window at its centre, through its touch shield.
    func tapFloaterWindow() throws {
        try FloaterTap.tapWindow(in: try #require(window))
    }

    /// A real tap at [point], in window points.
    func tapFloater(at point: CGPoint) throws {
        try TouchSynthesizer.tap(at: point, in: try #require(window))
    }

    /// Swipes down from the top of the expanded PiP: iOS's back for a full-screen floater (there
    /// is no system back on iOS), the strip `expandedChrome` routes to `expanded.onBack`.
    func swipeDownExpandedPip() throws {
        let window = try #require(window)
        let start = CGPoint(x: window.bounds.midX, y: window.safeAreaInsets.top + 70)
        try TouchSynthesizer.drag(
            from: start, by: CGVector(dx: 0, dy: 220), in: window, duration: 0.25, hold: 0)
    }
}
