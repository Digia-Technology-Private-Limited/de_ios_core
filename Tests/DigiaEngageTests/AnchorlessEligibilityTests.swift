import Foundation
import Testing
import UIKit
@testable import DigiaEngage

/// Pins the form-factor clause of `AnchorlessTarget.resolve`: a tablet is
/// eligible in portrait; landscape stays closed on every form factor.
/// Mirrors Android's `AnchorlessEligibilityTest`.
@MainActor
@Suite("Anchorless eligibility")
struct AnchorlessEligibilityTests {
    private func target() throws -> AnchorlessTarget {
        let json = """
        {
            "type": "anchorless",
            "version": 1,
            "pageKey": "cart",
            "imageUrl": "https://example.com/spotlight.png",
            "horizontal": {"frame": "window", "rule": {"kind": "startFixed", "startOffset": 16, "width": 153}},
            "vertical": {"frame": "window", "rule": {"kind": "topFixed", "topOffset": 102, "height": 54}}
        }
        """
        return try #require(AnchorlessTarget.decode(Data(json.utf8)))
    }

    private func window(width: CGFloat, height: CGFloat) -> UIWindow {
        UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test("tablet in portrait resolves a target")
    func tabletPortraitResolves() throws {
        let result = try target().resolve(
            currentPageKey: "cart", window: window(width: 768, height: 1024))
        #expect(result == .success(CGRect(x: 16, y: 102, width: 153, height: 54)))
    }

    @Test("phone in portrait stays eligible")
    func phonePortraitResolves() throws {
        let result = try target().resolve(
            currentPageKey: "cart", window: window(width: 390, height: 844))
        #expect(result == .success(CGRect(x: 16, y: 102, width: 153, height: 54)))
    }

    @Test("tablet in landscape stays closed")
    func tabletLandscapeUnsupported() throws {
        let result = try target().resolve(
            currentPageKey: "cart", window: window(width: 1024, height: 768))
        #expect(result == .failure(.unsupportedLayout))
    }

    @Test("phone in landscape stays closed")
    func phoneLandscapeUnsupported() throws {
        let result = try target().resolve(
            currentPageKey: "cart", window: window(width: 844, height: 390))
        #expect(result == .failure(.unsupportedLayout))
    }

    @Test("a different screen still fails before the layout check")
    func pageKeyMismatchFirst() throws {
        let result = try target().resolve(
            currentPageKey: "home", window: window(width: 768, height: 1024))
        #expect(result == .failure(.pageKeyMismatch))
    }
}
