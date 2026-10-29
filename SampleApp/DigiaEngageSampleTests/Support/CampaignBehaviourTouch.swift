import Testing
import UIKit
@testable import DigiaEngage

/// The real touches the campaign behaviour suites send, on top of the touch-free helpers in
/// `Tests/DigiaEngageTests/CampaignBehaviour/Support/CampaignBehaviour.swift`.
extension SdkHarness {

    /// A real touch at `point`, in window coordinates: a scrim, or a control with nothing to find it by.
    func touch(_ point: CGPoint) async throws {
        try TouchSynthesizer.tap(at: point, in: try #require(window))
        try await settle(0.5)
    }

    /// A real one-finger swipe from `start` to `end`, in window coordinates, then time for what it starts to settle.
    func swipe(from start: CGPoint, to end: CGPoint) async throws {
        try TouchSynthesizer.drag(
            from: start, by: CGVector(dx: end.x - start.x, dy: end.y - start.y),
            in: try #require(window), duration: 0.25)
        try await settle(1)
    }
}
