import Testing
import UIKit
@testable import DigiaEngage

/// The real touches and typing the legacy nudge and survey suites send, on top of the touch-free
/// helpers in `Tests/DigiaEngageTests/FixtureBehaviour/LegacySupport.swift`. The legacy shapes have no
/// canvas element ids, so a control is found by the text it shows (or the accessibility label SwiftUI
/// gives it).
extension SdkHarness {

    /// A real touch on the element whose shown text (or accessibility label) is exactly [text].
    /// Exact, not `contains`: the "Dark" option must not match the "Dark mode or light mode?" title.
    func legacyTapExact(_ text: String) async throws {
        try await legacyTap("\"\(text)\"") { Self.shownText(of: $0) == text }
    }

    /// As ``legacyTapExact(_:)``, for a control whose accessibility label joins several texts
    /// (a choice card reads "Developer, I write the code"): the first element starting with [text].
    func legacyTapPrefix(_ text: String) async throws {
        try await legacyTap("\"\(text)…\"") { Self.shownText(of: $0)?.hasPrefix(text) == true }
    }

    private func legacyTap(_ what: String, where match: @escaping (NSObject) -> Bool) async throws {
        let window = try #require(window)
        var last: CGRect?
        var steadyReads = 0
        // The same steady-frame wait `tap(id:)` uses: an entry animation moves the element first.
        do {
            try await waitUntil("\(what) settled on screen", timeout: 4) {
                guard let frame = Self.find(in: window, where: match)?.accessibilityFrame, !frame.isEmpty
                else { return false }
                steadyReads = frame == last ? steadyReads + 1 : 0
                last = frame
                return steadyReads >= 8
            }
        } catch {
            Issue.record("On screen instead: \(legacyShownTexts())")
            throw error
        }
        let frame = window.convert(try #require(last), from: window.screen.coordinateSpace)
        try TouchSynthesizer.tap(at: CGPoint(x: frame.midX, y: frame.midY), in: window)
        TouchSynthesizer.drainRunLoop(for: 0.2)
    }

    /// Types [text] into the one editable text field on screen, replacing what it held, through the
    /// field's own text input (what the keyboard calls), then lets the keyboard go unless
    /// [keepFocus] (call ``legacyDismissKeyboard()`` later).
    func legacyType(_ text: String, keepFocus: Bool = false) async throws {
        let window = try #require(window)
        try await waitUntil("a text field on screen") { Self.legacyEditableInput(in: window) != nil }
        let input = try #require(Self.legacyEditableInput(in: window))
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
        TouchSynthesizer.drainRunLoop(for: 0.4)
        if !keepFocus { legacyDismissKeyboard() }
    }

    /// Ends editing in the window, as tapping the keyboard away does.
    func legacyDismissKeyboard() {
        window?.endEditing(true)
        TouchSynthesizer.drainRunLoop(for: 0.5)
    }

    /// The text of the one editable field on screen, if any.
    func legacyFieldText() -> String? {
        guard let window, let input = Self.legacyEditableInput(in: window),
              let all = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        else { return nil }
        return input.text(in: all)
    }

    /// A tap near the top-left corner of the screen: the scrim of a dialog or sheet.
    func legacyTapBackdrop() throws {
        let window = try #require(window)
        try TouchSynthesizer.tap(at: CGPoint(x: 8, y: 80), in: window)
        TouchSynthesizer.drainRunLoop(for: 0.4)
    }

    private static func legacyEditableInput(in view: UIView) -> (UIView & UITextInput)? {
        guard !view.isHidden, view.alpha > 0.01 else { return nil }
        if let field = view as? UITextField, field.isEnabled { return field }
        if let textView = view as? UITextView, textView.isEditable { return textView }
        for subview in view.subviews {
            if let found = legacyEditableInput(in: subview) { return found }
        }
        return nil
    }
}
