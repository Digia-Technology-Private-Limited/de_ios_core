import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// What the legacy nudge and survey suites do on top of the shared `SdkHarness`: tap an exact label,
/// type into the one text field, tap the backdrop, and read what reached the backend (`/track`
/// events, `/recordSubmission` bodies). The legacy shapes have no canvas element ids, so a control
/// is found by the text it shows (or the accessibility label SwiftUI gives it).
extension SdkHarness {

    /// Boots the SDK serving [campaigns] and mounts a plain app under `DigiaHost`.
    static func legacyStart(_ campaigns: [[String: Any]]) async throws -> SdkHarness {
        let sdk = try await start(campaigns: campaigns)
        try sdk.mount { Text("legacy host app") }
        // The analytics queue outlives a test: events an earlier test left queued go out with the
        // first flush here. Send them now and read only what this test's requests carry.
        _ = try await sdk.events()
        legacyRequestBaseline[ObjectIdentifier(sdk)] = sdk.network.recordedRequests.count
        return sdk
    }

    /// The `/track` events sent since ``legacyStart(_:)``, in order.
    func legacyEvents() async throws -> [[String: Any]] {
        sdk.services?.analyticsService?.flush()
        try await settle(0.3)
        let baseline = legacyRequestBaseline[ObjectIdentifier(self)] ?? 0
        return network.recordedRequests.dropFirst(baseline)
            .filter { $0.url.absoluteString == DigiaEndpoints.track }
            .flatMap { request -> [[String: Any]] in
                guard let body = request.body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let events = json["events"] as? [[String: Any]]
                else { return [] }
                return events
            }
    }

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

    /// Every text on screen, in tree order: what a failed wait reports.
    func legacyShownTexts() -> [String] {
        guard let window else { return [] }
        var texts: [String] = []
        _ = Self.find(in: window) { object in
            if let text = Self.shownText(of: object), !text.isEmpty { texts.append(text) }
            return false
        }
        return texts
    }

    /// Whether an element whose shown text is exactly [text] is on screen.
    func legacyIsShowingExact(_ text: String) -> Bool {
        guard let window else { return false }
        return Self.find(in: window) { Self.shownText(of: $0) == text } != nil
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

    // MARK: - Reading the backend

    /// Every `/track` event named [name] for [campaignKey], in order. The analytics queue takes a
    /// moment to accept an event just emitted, so this reads again (for up to 3 s) until one is there.
    func legacyTracked(_ name: String, of campaignKey: String) async throws -> [[String: Any]] {
        var matching: [[String: Any]] = []
        for _ in 0..<10 {
            matching = try await legacyEvents().filter {
                $0["campaign_key"] as? String == campaignKey && $0["event_name"] as? String == name
            }
            if !matching.isEmpty { break }
        }
        return matching
    }

    /// The names of [campaignKey]'s `/track` events once [expected] is among them (or 3 s passed).
    func legacyEventNames(of campaignKey: String, once expected: String) async throws -> [String] {
        _ = try await legacyTracked(expected, of: campaignKey)
        return try await legacyEvents()
            .filter { $0["campaign_key"] as? String == campaignKey }
            .compactMap { $0["event_name"] as? String }
    }

    /// The properties of the only `/track` event named [name]; records an issue unless there is
    /// exactly one.
    func legacyOnly(_ name: String, of campaignKey: String) async throws -> [String: Any] {
        let matching = try await legacyTracked(name, of: campaignKey)
        #expect(matching.count == 1, "exactly one \"\(name)\", got \(matching.count)")
        return matching.first?["properties"] as? [String: Any] ?? [:]
    }

    /// The bodies posted to `/recordSubmission`, in order.
    func legacySubmissions() async throws -> [[String: Any]] {
        try await settle(0.4)
        return network.recordedRequests
            .filter { $0.url.absoluteString == DigiaEndpoints.submission }
            .compactMap { request in
                request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
    }
}

/// Per harness, how many requests had gone out when ``SdkHarness/legacyStart(_:)`` returned.
@MainActor private var legacyRequestBaseline: [ObjectIdentifier: Int] = [:]

extension CampaignPresentation {
    /// Whether the showing reached its authored end before it closed; nil until it is dismissed.
    var legacyCompleted: Bool? {
        if case .dismissed(_, let completed) = outcome.settledValue { return completed }
        return nil
    }
}

/// The `payload.responses` entry of a `/recordSubmission` body for [blockId].
func legacyResponse(_ body: [String: Any]?, _ blockId: String) -> [String: Any]? {
    let responses = (body?["payload"] as? [String: Any])?["responses"] as? [[String: Any]]
    return responses?.first { $0["blockId"] as? String == blockId }
}

/// A shared fixture under `campaigns/`, with [edit] applied to its `templateConfig` (or
/// `surveyConfig`): how a test holds a variant of a fixture without adding a fixture file.
func legacyFixture(
    _ path: String, editing key: String = "templateConfig", _ edit: (inout [String: Any]) -> Void
) throws -> [String: Any] {
    var campaign = try fixture(path)
    var config = try #require(campaign[key] as? [String: Any], "\(path) has no \(key)")
    edit(&config)
    campaign[key] = config
    return campaign
}
