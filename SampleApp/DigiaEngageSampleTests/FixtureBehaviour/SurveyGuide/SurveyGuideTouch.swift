import Testing
import UIKit
@testable import DigiaEngage

/// The real touches and typing the survey and guide behaviour suites send as a respondent, on top of
/// the touch-free helpers in `Tests/DigiaEngageTests/FixtureBehaviour/SurveyGuideSupport.swift`.
extension SdkHarness {

    /// A real touch on the element whose shown text (or accessibility label) is exactly [text].
    /// Exact, not `contains`: a rating star labelled "4" must not match "Rate 1 to 4".
    func tapExact(_ text: String) async throws {
        let window = try #require(window)
        let match: (NSObject) -> Bool = { Self.shownText(of: $0) == text }
        var last: CGRect?
        var steadyReads = 0
        // The same steady-frame wait `tap(id:)` uses: a scene transition moves the element first.
        try await waitUntil("\"\(text)\" settled on screen") {
            guard let frame = Self.find(in: window, where: match)?.accessibilityFrame, !frame.isEmpty
            else { return false }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 8
        }
        let frame = window.convert(try #require(last), from: window.screen.coordinateSpace)
        try TouchSynthesizer.tap(at: CGPoint(x: frame.midX, y: frame.midY), in: window)
    }

    func surveyNext() async throws { try await tapExact("Next") }
    func surveyBack() async throws { try await tapExact("Back") }

    /// Types [text] into the one editable text field on screen, replacing what it held, through
    /// the field's own text input (what the keyboard calls), then lets the keyboard go.
    func type(_ text: String) async throws {
        let window = try #require(window)
        // Exactly one: during a scene change the outgoing scene's field is still mounted, and
        // typing into it would answer the question just left.
        var steadyReads = 0
        try await waitUntil("one text field on screen") {
            steadyReads = Self.editableInputs(in: window).count == 1 ? steadyReads + 1 : 0
            return steadyReads >= 4
        }
        let input = try #require(Self.editableInputs(in: window).first)
        input.becomeFirstResponder()
        TouchSynthesizer.drainRunLoop(for: 0.2)
        if let all = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) {
            input.selectedTextRange = all
        }
        if text.isEmpty {
            input.deleteBackward()
        } else {
            input.insertText(text)
        }
        TouchSynthesizer.drainRunLoop(for: 0.2)
        input.resignFirstResponder()
        TouchSynthesizer.drainRunLoop(for: 0.4)
    }

    /// A tap at the top-left corner of the screen: the dialog's backdrop.
    func tapBackdrop() throws {
        let window = try #require(window)
        try TouchSynthesizer.tap(at: CGPoint(x: 5, y: 5), in: window)
        TouchSynthesizer.drainRunLoop(for: 0.3)
    }

    private static func editableInputs(in view: UIView) -> [UIView & UITextInput] {
        guard !view.isHidden, view.alpha > 0.01 else { return [] }
        if let field = view as? UITextField, field.isEnabled { return [field] }
        if let textView = view as? UITextView, textView.isEditable { return [textView] }
        return view.subviews.flatMap { editableInputs(in: $0) }
    }
}
