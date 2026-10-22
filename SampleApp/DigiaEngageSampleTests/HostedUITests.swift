import Testing
import UIKit
@testable import DigiaEngage

/// Parent of every suite here that renders through a key window or the SDK's shared controllers.
///
/// Those suites share the SDK's process-wide singletons, so two running at once would spoil each
/// other's frames and state. `.serialized` on this parent runs every nested suite one at a time,
/// as `RenderedUITests` does in the package tests. Nest a new suite with
/// `extension HostedUITests { … }`.
@Suite(.serialized)
struct HostedUITests {}

/// Tapping the floaters as a user does, for the suites nested in `HostedUITests`.
@MainActor
enum FloaterTap {

    /// The floater window's on-screen rect, read from the production touch shield: it is the rect
    /// the shield hit-tests against, so its centre is a point a user's tap would open.
    static func windowRect(in window: UIWindow) throws -> CGRect {
        let shield = try #require(find(FloaterTouchShieldView.self, in: window), "No floater touch shield on screen")
        try #require(!shield.activeRect.isNull, "The floater touch shield has no active rect")
        return shield.convert(shield.activeRect, to: window)
    }

    /// Taps the centre of the floater window.
    static func tapWindow(in window: UIWindow) throws {
        let rect = try windowRect(in: window)
        try TouchSynthesizer.tap(at: CGPoint(x: rect.midX, y: rect.midY), in: window)
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}
