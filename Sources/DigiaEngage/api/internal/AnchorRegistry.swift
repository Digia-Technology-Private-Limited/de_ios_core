import Foundation
import CoreGraphics

/// Stores screen-coordinate rects for named anchor views so the guide overlay
/// can position itself relative to them. Coordinates only — no UIView refs
/// needed on iOS since rendering is pure SwiftUI using the stored CGRect.
@MainActor
final class AnchorRegistry {
    static let shared = AnchorRegistry()

    private var anchors: [String: CGRect] = [:]
    private init() {}

    func register(key: String, rect: CGRect) {
        anchors[key] = rect
    }

    func unregister(key: String) {
        anchors.removeValue(forKey: key)
    }

    func find(_ key: String) -> CGRect? {
        anchors[key]
    }
}
