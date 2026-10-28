import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// Real touches for the shared `SdkHarness` (`Tests/DigiaEngageTests/Support/SdkHarness.swift`).
///
/// The package test bundle has no `UIApplication`, so there a control is activated through
/// accessibility. Hosted by the sample app, a test taps the way a finger does: `TouchSynthesizer`
/// hands UIKit a digitizer event, and UIKit hit-tests and dispatches it, so a tap the surface
/// refuses or a recognizer swallows fails the test.
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
    ///
    /// A harness started from workspace fixtures finds the text with `UIProbe` instead, and settles after.
    func tap(text: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        guard servesWorkspaceFixtures else {
            try await tap("text \(text)") { Self.shownText(of: $0)?.contains(text) == true }
            return
        }
        let point = try #require(
            UIProbe.center(ofText: text, in: window), "nothing on screen shows \"\(text)\"",
            sourceLocation: sourceLocation)
        try TouchSynthesizer.tap(at: point, in: window)
        try await settle(0.5)
    }

    private func tap(_ what: String, where match: @escaping (NSObject) -> Bool) async throws {
        let window = try #require(window)
        var last: CGRect?
        var steadyReads = 0
        try await waitUntil("\(what) settled on screen", timeout: 8) {
            guard let frame = Self.find(in: window, where: match)?.accessibilityFrame, !frame.isEmpty
            else { return false }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 8 // 8 reads, 50 ms apart
        }
        let frame = window.convert(try #require(last), from: window.screen.coordinateSpace)
        try TouchSynthesizer.tap(at: CGPoint(x: frame.midX, y: frame.midY), in: window)
    }
}
