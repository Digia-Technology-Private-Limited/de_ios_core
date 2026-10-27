import Testing
import UIKit

/// The part of ``SdkHarness`` that needs the sample app host: real touches through
/// `TouchSynthesizer`, and the view controller presented over the app. The core harness, compiled
/// into the package's test target too, is `Tests/DigiaEngageTests/Support/SdkHarness.swift`.
extension SdkHarness {

    /// A real touch at the centre of the canvas element authored with [id] (`TestView` sets it as
    /// the accessibility identifier in debug builds). Waits for the element to stop moving first: a
    /// surface's entry animation would otherwise send the touch to where the element *was*.
    ///
    /// The frame must also hold for 400 ms, not just a few reads. SwiftUI lists a just-presented
    /// element in the accessibility tree, at its final frame, before the surface takes touches:
    /// the canvas dialog nudge sent a touch at that moment to its backdrop 2–4 times in 10, while
    /// waiting 400 ms passed 10 in 10. There is no public signal for "accepts touches", and
    /// Core Animation sees no running animation then either.
    func tap(id: String) async throws {
        try await tap("element \(id)") { Self.identifier(of: $0) == id }
    }

    /// As ``tap(id:)``, for the element that shows [text] (an option label has no id of its own).
    func tap(text: String) async throws {
        try await tap("text \(text)") { Self.shownText(of: $0)?.contains(text) == true }
    }

    /// The view controller presented over the app (a full-screen viewer, a sheet), if any.
    var presentedViewer: UIViewController? {
        window?.rootViewController?.presentedViewController
    }

    private func tap(_ what: String, where match: @escaping (NSObject) -> Bool) async throws {
        let window = try #require(window)
        var last: CGRect?
        var steadyReads = 0
        try await waitUntil("\(what) settled on screen") {
            guard let frame = Self.find(in: window, where: match)?.accessibilityFrame, !frame.isEmpty
            else { return false }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 8 // 8 reads, 50 ms apart
        }
        let frame = window.convert(try #require(last), from: window.screen.coordinateSpace)
        try TouchSynthesizer.tap(at: CGPoint(x: frame.midX, y: frame.midY), in: window)
    }

    private static func identifier(of object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}
