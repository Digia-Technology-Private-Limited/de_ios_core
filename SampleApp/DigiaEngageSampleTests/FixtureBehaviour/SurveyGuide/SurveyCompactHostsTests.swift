import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// `survey_compact_answer_hosts`: every answer area is deliberately short (10 to 27 % of the
/// canvas). An answer input must scale itself to the host it was given, so its options and its
/// validation message stay inside that area instead of spilling over the neighbouring content.
///
/// Each scene is shown on the phone, Next is tapped with nothing answered so the validation
/// message appears, and the rectangle of that message and of the options is compared with the
/// answer host's rectangle computed from the fixture. Every scene's prompt shares its answer
/// host's x and width, so the prompt's on-screen frame gives the canvas scale and origin.
///
/// Port of `flutter/core/test/fixture_behaviour/survey_compact_hosts_test.dart`.
@Suite("Survey: compact answer hosts", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyCompactHostsTests {

    private static let path = "campaigns/survey/survey_compact_answer_hosts.json"
    private static let key = "test_survey_compact_answer_hosts"

    /// The canvas rects (fractions) of [sceneId]'s prompt and answer host, from the fixture.
    private func fractions(_ sceneId: String) throws -> (prompt: CGRect, host: CGRect, canvas: CGSize) {
        let template = try #require(try loadCampaign(Self.path)["templateConfig"] as? [String: Any])
        let scenes = try #require(template["scenes"] as? [[String: Any]])
        let scene = try #require(scenes.first { $0["id"] as? String == sceneId })
        let canvas = try #require(scene["canvas"] as? [String: Any])
        let children = try #require(canvas["children"] as? [[String: Any]])
        func rect(_ child: [String: Any]?) throws -> CGRect {
            let r = try #require(child?["rect"] as? [String: Double])
            return CGRect(x: r["x"]!, y: r["y"]!, width: r["width"]!, height: r["height"]!)
        }
        let prompt = try rect(children.first { $0["id"] as? String == "prompt_\(sceneId)" })
        let host = try rect(children.first {
            ($0["element"] as? [String: Any])?["type"] as? String == "canvasSurvey.answerInput"
        })
        let size = CGSize(width: canvas["canvasWidth"] as? Double ?? 360, height: canvas["canvasHeight"] as? Double ?? 600)
        return (prompt, host, size)
    }

    /// Where the answer host of [sceneId] is on screen now, from its prompt's on-screen frame.
    private func hostOnScreen(_ sdk: SdkHarness, _ sceneId: String) throws -> CGRect {
        let f = try fractions(sceneId)
        let element = try #require(sdk.element(id: "prompt_\(sceneId)") ?? sdk.element(id: "w_prompt_\(sceneId)"),
                                   "the prompt of \(sceneId) on screen")
        let prompt = try frame(sdk, of: element)
        let scale = prompt.width / (f.prompt.width * f.canvas.width)
        let originY = prompt.minY - f.prompt.minY * f.canvas.height * scale
        let originX = prompt.minX - f.prompt.minX * f.canvas.width * scale
        return CGRect(
            x: originX + f.host.minX * f.canvas.width * scale,
            y: originY + f.host.minY * f.canvas.height * scale,
            width: f.host.width * f.canvas.width * scale,
            height: f.host.height * f.canvas.height * scale)
    }

    private func frame(_ sdk: SdkHarness, of element: NSObject) throws -> CGRect {
        let window = try #require(sdk.window)
        return window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace)
    }

    private func frame(_ sdk: SdkHarness, exactly text: String) throws -> CGRect {
        let window = try #require(sdk.window)
        let element = try #require(SdkHarness.find(in: window) { SdkHarness.shownText(of: $0) == text },
                                   "\"\(text)\" on screen")
        return try frame(sdk, of: element)
    }

    /// A tile's frame includes the half of its border stroke drawn outside it (the stroke
    /// straddles the edge; up to 4 pt wide when scaled), so a host is allowed that much.
    private static let strokeSlack: CGFloat = 2

    private func expectInside(_ inner: CGRect, _ host: CGRect, _ what: String) {
        let slack = Self.strokeSlack
        #expect(inner.minX >= host.minX - slack, "\(what) spills left of its host \(host) (is \(inner))")
        #expect(inner.minY >= host.minY - slack, "\(what) spills above its host \(host) (is \(inner))")
        #expect(inner.maxX <= host.maxX + slack, "\(what) spills right of its host \(host) (is \(inner))")
        #expect(inner.maxY <= host.maxY + slack, "\(what) spills below its host \(host) (is \(inner))")
    }

    /// Taps Next with nothing answered and checks the message that appears, and [content].
    private func refuseEmpty(
        _ sdk: SdkHarness, sceneId: String, message: String, content: [String], contentFrames: [CGRect] = []
    ) async throws {
        try await sdk.surveyNext()
        try await sdk.waitUntil("\(sceneId) refuses an empty answer with \"\(message)\"") { sdk.isShowing(message) }
        let host = try hostOnScreen(sdk, sceneId)
        let messageRect = try frame(sdk, exactly: message)
        expectInside(messageRect, host, "\"\(message)\"")
        let rects = try content.map { ($0, try frame(sdk, exactly: $0)) } + contentFrames.map { ("field", $0) }
        for (what, rect) in rects {
            expectInside(rect, host, what)
            // The message has a slot of its own at the foot of the host.
            #expect(rect.maxY <= messageRect.minY + Self.strokeSlack,
                    "\(what) runs into the message slot (is \(rect), message at \(messageRect))")
        }
    }

    // Fails if: CanvasSurveyAnswerMetrics.swift `compute` stops deriving `scaleFactor` (and the
    // reserved `validationErrorHeight`) from the host height, so options grow past a short host or
    // into the message slot.
    @Test("answer inputs and their validation messages stay inside a compact host, scene by scene")
    func staysInsideCompactHosts() async throws {
        let sdk = try await SdkHarness.surveyGuideStart([Self.path])
        defer { sdk.tearDown() }
        try await sdk.openSurvey(Self.key, firstText: "Pick the delivery you prefer")

        // Four choice tiles in a host a fifth of the canvas tall.
        try await refuseEmpty(sdk, sceneId: "scene_grid", message: "Select an option",
                              content: ["Standard delivery", "Parcel locker, collect any time"])
        try await sdk.tapExact("Express")
        try await sdk.surveyNext()

        // A multi select capped at one: the message for an empty answer.
        try await sdk.waitUntil("the capped multi select") { sdk.isShowing("Pick one favourite") }
        try await refuseEmpty(sdk, sceneId: "scene_cap_one", message: "Select at least one option",
                              content: ["Yes", "No"])
        try await sdk.tapExact("Yes")
        try await sdk.surveyNext()

        // Eleven NPS tiles in a host a tenth of the canvas tall.
        try await sdk.waitUntil("the NPS") { sdk.isShowing("How likely are you to recommend us?") }
        try await refuseEmpty(sdk, sceneId: "scene_nps", message: "Choose a rating", content: ["0", "10"])
        try await sdk.tapExact("9")
        try await sdk.surveyNext()

        try await sdk.waitUntil("the rating") { sdk.isShowing("Rate your last order") }
        try await refuseEmpty(sdk, sceneId: "scene_rating", message: "Choose a rating", content: ["1", "5"])
        try await sdk.tapExact("4")
        try await sdk.surveyNext()

        // The reaction faces are images with no label: only the message is checked, and the
        // middle face (3) is tapped at the centre of the host.
        try await sdk.waitUntil("the reaction") { sdk.isShowing("How did it feel?") }
        try await refuseEmpty(sdk, sceneId: "scene_reaction", message: "Choose a rating", content: [])
        let window = try #require(sdk.window)
        let reactionHost = try hostOnScreen(sdk, "scene_reaction")
        try TouchSynthesizer.tap(at: CGPoint(x: reactionHost.midX, y: reactionHost.minY + reactionHost.height * 0.3),
                                 in: window)
        try await sdk.surveyNext()

        // A long text answer fills its host and keeps the message inside it.
        try await sdk.waitUntil("the long text") { sdk.isShowing("Tell us more") }
        let field = try #require(SdkHarness.find(in: window) { ($0 as? UITextView)?.isEditable == true })
        try await refuseEmpty(sdk, sceneId: "scene_long", message: "This field is required", content: [],
                              contentFrames: [try frame(sdk, of: field)])
        try await sdk.type("Faster delivery slots")
        try await sdk.surveyNext()

        try await sdk.waitUntil("the thank-you page") { sdk.isShowing("Thanks!") }
    }
}
}
