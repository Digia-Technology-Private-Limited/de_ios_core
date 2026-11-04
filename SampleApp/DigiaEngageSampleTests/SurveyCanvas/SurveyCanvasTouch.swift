import Testing
import UIKit
@testable import DigiaEngage

/// The real touches a respondent sends to a canvas survey, on top of the touch-free helpers in
/// `Tests/DigiaEngageTests/FixtureBehaviour/SurveyCanvasSupport.swift`.
extension SdkHarness {

    /// A real touch on the one visible element that shows exactly [text] (see
    /// ``surveyCanvasShows(_:_:)``), once its frame is steady.
    func surveyCanvasTap(_ text: String) async throws {
        let window = try #require(window)
        var last: CGRect?
        var steadyReads = 0
        try await waitUntil("\"\(text)\" settled on screen", timeout: 5) {
            guard let frame = Self.find(in: window, where: { Self.surveyCanvasShows($0, text) })?
                .accessibilityFrame, !frame.isEmpty
            else { return false }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 8
        }
        // The visible part only: a tile in a horizontally scrolling row can run past the screen.
        let frame = window.convert(try #require(last), from: window.screen.coordinateSpace)
            .intersection(window.bounds)
        try #require(!frame.isNull, "\"\(text)\" is off screen")
        try TouchSynthesizer.tap(at: CGPoint(x: frame.midX, y: frame.midY), in: window)
        TouchSynthesizer.drainRunLoop(for: 0.1)
    }
}
