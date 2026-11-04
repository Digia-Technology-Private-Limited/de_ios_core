import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// A shared survey fixture as a deep mutable copy, so a test can change one scene, host or setting
/// in place (NSMutableDictionary is a reference: editing a nested container edits the campaign)
/// instead of adding a near-duplicate fixture.
@MainActor
struct SurveyCanvasCampaign {
    let root: NSMutableDictionary

    init(_ path: String) throws {
        let campaign = try loadCampaign("campaigns/\(path).json")
        let data = try JSONSerialization.data(withJSONObject: campaign)
        root = try #require(
            try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? NSMutableDictionary)
    }

    var key: String { root["campaignKey"] as? String ?? "" }
    var json: [String: Any] { root as? [String: Any] ?? [:] }

    var template: NSMutableDictionary {
        get throws { try #require(root["templateConfig"] as? NSMutableDictionary) }
    }

    /// `templateConfig.behavior`, created when missing.
    var behavior: NSMutableDictionary {
        get throws {
            let template = try template
            if let behavior = template["behavior"] as? NSMutableDictionary { return behavior }
            let behavior = NSMutableDictionary()
            template["behavior"] = behavior
            return behavior
        }
    }

    func scene(_ id: String) throws -> NSMutableDictionary {
        let scenes = try #require(try template["scenes"] as? NSMutableArray)
        return try #require(
            scenes.compactMap { $0 as? NSMutableDictionary }.first { $0["id"] as? String == id },
            "scene \(id)")
    }

    /// The scene's `input`.
    func input(_ sceneId: String) throws -> NSMutableDictionary {
        try #require(try scene(sceneId)["input"] as? NSMutableDictionary, "input of \(sceneId)")
    }

    /// The scene's answer host element's `props`.
    func answerHostProps(_ sceneId: String) throws -> NSMutableDictionary {
        let host = try #require(try children(of: scene(sceneId)).first {
            (($0["element"] as? NSDictionary)?["type"] as? String) == "canvasSurvey.answerInput"
        }, "answer host of \(sceneId)")
        let element = try #require(host["element"] as? NSMutableDictionary)
        if let props = element["props"] as? NSMutableDictionary { return props }
        let props = NSMutableDictionary()
        element["props"] = props
        return props
    }

    /// Removes the scene's answer host, leaving its input.
    func removeAnswerHost(_ sceneId: String) throws {
        let canvas = try #require(try scene(sceneId)["canvas"] as? NSMutableDictionary)
        let children = try #require(canvas["children"] as? NSMutableArray)
        let kept = children.filter {
            ((($0 as? NSDictionary)?["element"] as? NSDictionary)?["type"] as? String) != "canvasSurvey.answerInput"
        }
        canvas["children"] = NSMutableArray(array: kept)
    }

    /// The `props` of the shared managed host with [id] (`survey_primary`, `survey_back`, ...).
    func sharedHostProps(_ id: String) throws -> NSMutableDictionary {
        let shared = try #require(try template["sharedUi"] as? NSMutableDictionary)
        let canvas = try #require(shared["canvas"] as? NSMutableDictionary)
        let host = try #require(try children(of: ["canvas": canvas]).first { $0["id"] as? String == id }, "shared host \(id)")
        return try #require((host["element"] as? NSMutableDictionary)?["props"] as? NSMutableDictionary)
    }

    /// Adds a shared managed host with [role] at the top of the stage, and lists it on every scene
    /// whose `sharedUi` names the hosts it shows (a scene only shows the hosts it lists).
    func addSharedHost(id: String, role: String, rect: [String: Double]) throws {
        let shared = try #require(try template["sharedUi"] as? NSMutableDictionary)
        let canvas = try #require(shared["canvas"] as? NSMutableDictionary)
        let children = try #require(canvas["children"] as? NSMutableArray)
        children.add(NSMutableDictionary(dictionary: [
            "kind": "hostElement",
            "id": id,
            "rect": rect,
            "element": [
                "type": "canvasSurvey.managed",
                "props": [
                    "role": role, "shared": true, "visible": true,
                    "color": ["value": "#252521"], "fontSize": 14, "padding": 2,
                ],
            ],
        ]))
        let scenes = try #require(try template["scenes"] as? NSMutableArray)
        for case let scene as NSMutableDictionary in scenes {
            guard let override = scene["sharedUi"] as? NSMutableDictionary,
                  let listed = override["children"] as? NSMutableArray, listed.count > 0 else { continue }
            listed.add(NSMutableDictionary(dictionary: ["id": id, "rect": rect]))
        }
    }

    private func children(of scene: NSDictionary) throws -> [NSMutableDictionary] {
        let canvas = try #require(scene["canvas"] as? NSDictionary)
        return (canvas["children"] as? NSArray)?.compactMap { $0 as? NSMutableDictionary } ?? []
    }
}

/// Opening a canvas survey and reading what it shows and what reached the backend. Kept apart from
/// the other survey suites' helpers (names prefixed) so each folder builds on its own. The taps are
/// the sample app's (`SurveyCanvasTouch.swift`).
///
/// Compiled into both test targets, as `SdkHarness.swift` is.
extension SdkHarness {

    static func surveyCanvasStart(_ campaign: SurveyCanvasCampaign) async throws -> SdkHarness {
        let sdk = try await start(campaign.json)
        SurveyCanvasRun.startedAt = Date()
        try sdk.mount { Text("home") }
        return sdk
    }

    /// Delivers [key] and waits for [firstText] on screen.
    @discardableResult
    func surveyCanvasOpen(_ key: String, firstText: String) async throws -> CampaignPresentation {
        let presentation = try deliver(key)
        try await waitUntil("the survey shows \"\(firstText)\"", timeout: 5) { self.isShowing(firstText) }
        return presentation
    }

    /// Whether [object] shows exactly [text], alone or as one part of a combined accessibility
    /// label: a choice tile reads "✓, Search" once chosen, an upvote tile "Search, ↑".
    static func surveyCanvasShows(_ object: NSObject, _ text: String) -> Bool {
        guard let shown = shownText(of: object) else { return false }
        return shown == text || shown.components(separatedBy: ", ").contains(text)
    }

    /// The combined accessibility labels on screen that include [text], for diagnostics.
    func surveyCanvasLabels(containing text: String) -> [String] {
        guard let window else { return [] }
        var labels: [String] = []
        Self.surveyCanvasCollect(in: window) { Self.shownText(of: $0)?.contains(text) == true } into: {
            if let label = Self.shownText(of: $0), !labels.contains(label) { labels.append(label) }
        }
        return labels
    }

    /// The window frames of every visible element whose text is exactly [text].
    func surveyCanvasFrames(_ text: String) -> [CGRect] {
        guard let window else { return [] }
        var frames: [CGRect] = []
        Self.surveyCanvasCollect(in: window) { Self.surveyCanvasShows($0, text) } into: { object in
            let frame = window.convert(object.accessibilityFrame, from: window.screen.coordinateSpace).integral
            if !frame.isEmpty, !frames.contains(frame) { frames.append(frame) }
        }
        return frames
    }

    /// The first visible view of type [type] in the window (and anything presented over it).
    func surveyCanvasView<T: UIView>(_ type: T.Type) -> T? {
        guard let window else { return nil }
        return Self.surveyCanvasFirst(T.self, in: window)
    }

    private static func surveyCanvasFirst<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        guard !view.isHidden, view.alpha > 0.01 else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = surveyCanvasFirst(type, in: subview) { return found }
        }
        return nil
    }

    private static func surveyCanvasCollect(
        in root: NSObject, depth: Int = 0, where match: (NSObject) -> Bool, into found: (NSObject) -> Void
    ) {
        guard depth < 60 else { return }
        if let view = root as? UIView, view.isHidden || view.alpha <= 0.01 { return }
        if match(root) { found(root) }
        if let view = root as? UIView {
            for subview in view.subviews { surveyCanvasCollect(in: subview, depth: depth + 1, where: match, into: found) }
        }
        if let elements = root.accessibilityElements {
            for case let element as NSObject in elements {
                surveyCanvasCollect(in: element, depth: depth + 1, where: match, into: found)
            }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = root.accessibilityElement(at: index) as? NSObject {
                        surveyCanvasCollect(in: element, depth: depth + 1, where: match, into: found)
                    }
                }
            }
        }
    }

    /// Every `/track` event of [campaignKey] named [name] that occurred since
    /// ``surveyCanvasStart(_:)``. The analytics queue outlives an SDK reset, so an earlier test's
    /// last events can arrive during this one.
    ///
    /// Waits (up to 3 s) for at least [atLeast] of them: a flush asked for while the queue is
    /// already posting is skipped, so an event can reach the backend a beat after it fired.
    func surveyCanvasTracked(
        _ name: String, of campaignKey: String, atLeast: Int = 0
    ) async throws -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let since = SurveyCanvasRun.startedAt
        let deadline = Date().addingTimeInterval(3)
        while true {
            let matching = try await events().filter { event in
                guard event["campaign_key"] as? String == campaignKey, event["event_name"] as? String == name
                else { return false }
                guard let raw = event["occurred_at"] as? String, let at = formatter.date(from: raw) else { return true }
                return at >= since
            }
            if matching.count >= atLeast || Date() > deadline { return matching }
        }
    }

    /// The `answer.values` of every `Digia Question Answered` of [campaignKey] for [questionId].
    func surveyCanvasAnswers(_ campaignKey: String, question questionId: String) async throws -> [[String]] {
        try await surveyCanvasTracked("Digia Question Answered", of: campaignKey, atLeast: 1).compactMap { event in
            let props = event["properties"] as? [String: Any] ?? [:]
            guard props["question_id"] as? String == questionId else { return nil }
            return (props["answer"] as? [String: Any])?["values"] as? [String] ?? []
        }
    }
}

@MainActor
enum SurveyCanvasRun {
    static var startedAt = Date.distantPast
}
