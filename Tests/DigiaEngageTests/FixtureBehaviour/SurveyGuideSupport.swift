import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// What the survey and guide behaviour suites do on top of the shared `SdkHarness`: boot the app,
/// read the screen, and read what reached the backend (`/track` events, `/recordSubmission` bodies).
/// Acting as a respondent (taps, typing, the backdrop) is the sample app's `SurveyGuideTouch.swift`.
/// Mirrors `flutter/core/test/fixture_behaviour/support/survey_support.dart`.
///
/// Compiled into both test targets, as `SdkHarness.swift` is.
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

/// The `degrade_survey_*` bundle the survey degradation suites boot: surveys this build must not show,
/// or must show only in part, with a good survey (`survey_welcome_backdrop_stepback`) in the middle.
@MainActor
enum SurveyDegradationBundle {
    static let goodKey = "test_survey_welcome_backdrop_stepback"
    /// Dropped by the parser as unreadable, by the key each reports under.
    static let unreadable = [
        "test_degrade_survey_flow_root_missing",
        "test_degrade_survey_no_design_width",
        "test_degrade_survey_no_scenes",
        "test_degrade_survey_not_a_survey_template",
        "test_degrade_survey_schema_older",
    ]
    /// Known gap: three of the surveys Flutter drops as unreadable are parsed and shown by iOS,
    /// which repairs them in canvas_survey_config_parser.swift instead of rejecting them:
    ///   flow_root_missing  `rootNodeId` names no node; iOS falls back to `nodes.first?.id`
    ///   no_design_width    `designWidth: 0`; `designWidth(_:)` falls back to 360
    ///   schema_older       `schemaVersion: 0`; `schemaVersion(_:)` reads it as the supported 1
    ///                      (`SurveyParse.int(raw) ?? 1`), so `acceptsVersion` never sees 0
    /// Each is checked under `withKnownIssue`, which fails the day iOS drops it, the cue to move
    /// it out of this set.
    static let iosKeeps: Set<String> = [
        "test_degrade_survey_flow_root_missing",
        "test_degrade_survey_no_design_width",
        "test_degrade_survey_schema_older",
    ]
    static let newerKey = "test_degrade_survey_schema_newer"
    static let partialKey = "test_degrade_survey_partial_scenes"

    static func boot() async throws -> SdkHarness {
        // Dedup is per app session and the sink is a singleton, so a reason reported by an
        // earlier test would hide the same reason in this one.
        HealthSink.shared.resetForTest()
        let degrade = { (name: String) in "campaigns/degradation/degrade_survey_\(name).json" }
        return try await SdkHarness.surveyGuideStart([
            degrade("flow_root_missing"),
            degrade("no_design_width"),
            degrade("no_scenes"),
            // A readable survey among the unreadable ones.
            "campaigns/survey/survey_welcome_backdrop_stepback.json",
            degrade("not_a_survey_template"),
            degrade("schema_older"),
            degrade("schema_newer"),
            degrade("partial_scenes"),
        ])
    }
}
