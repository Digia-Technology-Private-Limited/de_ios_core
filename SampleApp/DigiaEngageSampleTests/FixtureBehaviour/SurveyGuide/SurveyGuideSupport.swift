import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// What the survey and guide behaviour suites do on top of the shared `SdkHarness`: act as a
/// respondent (tap an exact label, type into the one text field, tap the backdrop) and read what
/// reached the backend (`/track` events, `/recordSubmission` bodies). Mirrors
/// `flutter/core/test/fixture_behaviour/support/survey_support.dart`.
extension SdkHarness {

    /// Boots the SDK serving the shared fixtures at [paths] (under `sdk_testing_fixtures/`), mounts
    /// a plain app under `DigiaHost`, and leaves the CEP ready to deliver.
    static func surveyGuideStart(_ paths: [String]) async throws -> SdkHarness {
        SurveyGuideRun.startedAt = Date()
        let sdk = try await start(campaigns: paths.map { try loadCampaign($0) })
        try sdk.mount { Text("home") }
        return sdk
    }

    /// Delivers [key] and waits for [firstText] to be on screen.
    @discardableResult
    func openSurvey(_ key: String, firstText: String) async throws -> CampaignPresentation {
        let presentation = try deliver(key)
        do {
            try await waitUntil("the survey shows \"\(firstText)\"", timeout: 4) { self.isShowing(firstText) }
        } catch {
            Issue.record("\(key) outcome: \(String(describing: presentation.outcome.settledValue)), survey state: \(sdk.surveyOrchestrator.state != nil)")
            throw error
        }
        return presentation
    }

    // MARK: - Acting

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

    // MARK: - Reading the screen

    /// The on-screen frames (window coordinates) of every visible element whose shown text is
    /// exactly [text], one per distinct frame (a view and its accessibility element count once).
    func frames(exactly text: String) -> [CGRect] {
        guard let window else { return [] }
        var frames: [CGRect] = []
        Self.collect(in: window) { Self.shownText(of: $0) == text } into: { object in
            let frame = window.convert(object.accessibilityFrame, from: window.screen.coordinateSpace).integral
            if !frame.isEmpty, !frames.contains(frame) { frames.append(frame) }
        }
        return frames
    }

    private static func collect(
        in root: NSObject, depth: Int = 0, where match: (NSObject) -> Bool, into found: (NSObject) -> Void
    ) {
        guard depth < 60 else { return }
        if let view = root as? UIView, view.isHidden || view.alpha <= 0.01 { return }
        if match(root) { found(root) }
        if let view = root as? UIView {
            for subview in view.subviews { collect(in: subview, depth: depth + 1, where: match, into: found) }
        }
        if let elements = root.accessibilityElements {
            for case let element as NSObject in elements {
                collect(in: element, depth: depth + 1, where: match, into: found)
            }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = root.accessibilityElement(at: index) as? NSObject {
                        collect(in: element, depth: depth + 1, where: match, into: found)
                    }
                }
            }
        }
    }

    /// Scrolls the first scroll view of the presented screen down, a page at a time, until an
    /// element showing exactly [text] is drawn.
    func scrollUntilShowing(_ text: String) async throws {
        let root = try #require(window?.rootViewController?.presentedViewController?.view)
        let scroll = try #require(Self.firstScrollView(in: root), "a scrolling list on screen")
        for _ in 0..<20 {
            if !frames(exactly: text).isEmpty { return }
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            if scroll.contentOffset.y >= maxY { break }
            scroll.setContentOffset(CGPoint(x: 0, y: min(maxY, scroll.contentOffset.y + scroll.bounds.height / 2)),
                                    animated: false)
            try await settle(0.3)
        }
        #expect(!frames(exactly: text).isEmpty, "\"\(text)\" never scrolled into view")
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Reading the backend

    /// Every `/track` event this harness's network received that occurred since
    /// ``surveyGuideStart(_:)``, including those sent while `initialize` ran (which `events()`
    /// leaves out), after flushing what is queued.
    func trackedSinceStart() async throws -> [[String: Any]] {
        sdk.services?.analyticsService?.flush()
        try await settle(0.3)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let since = SurveyGuideRun.startedAt
        return network.recordedRequests
            .filter { $0.url.absoluteString == DigiaEndpoints.track }
            .flatMap { request -> [[String: Any]] in
                guard let body = request.body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let events = json["events"] as? [[String: Any]]
                else { return [] }
                return events
            }
            .filter { event in
                guard let raw = event["occurred_at"] as? String, let at = formatter.date(from: raw) else { return true }
                return at >= since
            }
    }

    /// Every `/track` event named [name] for [campaignKey] this test sent, in order.
    func tracked(_ name: String, of campaignKey: String) async throws -> [[String: Any]] {
        try await events().filter {
            $0["campaign_key"] as? String == campaignKey && $0["event_name"] as? String == name
        }
    }

    /// The properties of the one `/track` event named [name]; records an issue unless there is
    /// exactly one.
    func only(_ name: String, of campaignKey: String) async throws -> [String: Any] {
        let matching = try await tracked(name, of: campaignKey)
        #expect(matching.count == 1, "exactly one \"\(name)\", got \(matching.count)")
        return matching.first.map(Self.props) ?? [:]
    }

    static func props(_ event: [String: Any]) -> [String: Any] {
        event["properties"] as? [String: Any] ?? [:]
    }

    /// The question ids shown so far, in order.
    func questionsViewed(_ campaignKey: String) async throws -> [String] {
        try await tracked("Digia Question Viewed", of: campaignKey)
            .compactMap { Self.props($0)["question_id"] as? String }
    }

    /// The bodies posted to `/recordSubmission`, in order.
    func submissions() async throws -> [[String: Any]] {
        try await settle(0.3)
        return network.recordedRequests
            .filter { $0.url.absoluteString == DigiaEndpoints.submission }
            .compactMap { request in
                request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
    }
}

/// When the current test's SDK was started, for ``SdkHarness/trackedSinceStart()``.
@MainActor
enum SurveyGuideRun {
    static var startedAt = Date.distantPast
}

/// The `values` of one question's answer in a `Digia Experience Completed` `response`, and whether
/// its `comment` is absent or null.
func surveyAnswer(_ response: [String: Any]?, _ nodeId: String) -> (values: [String], noComment: Bool)? {
    guard let answer = response?[nodeId] as? [String: Any] else { return nil }
    let comment = answer["comment"]
    return (answer["values"] as? [String] ?? [], comment == nil || comment is NSNull)
}
