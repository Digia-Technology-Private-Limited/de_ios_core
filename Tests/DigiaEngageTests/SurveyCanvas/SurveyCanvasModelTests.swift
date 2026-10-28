import Foundation
import Testing
@testable import DigiaEngage

/// Decisions in the canvas survey models that the hosted fixture suites cannot reach from the
/// screen: which answers the validator accepts at the edges, which inputs may auto-advance, how
/// the input parser reads authored aliases and limits, and how the document parser degrades a
/// scene it cannot read instead of failing the survey.
///
/// No Flutter unit test covers these one by one; the Flutter behaviour they mirror is driven by
/// `flutter/core/test/fixture_behaviour/survey_validation_rules_test.dart` and
/// `survey_degradation_test.dart`.
@Suite("Canvas survey: models", .tags(.unit, .survey))
struct SurveyCanvasModelTests {

    private func object(_ json: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case .object(let object) = value else {
            Issue.record("not an object: \(json)")
            return [:]
        }
        return object
    }

    private func input(_ json: String) throws -> CanvasSurveyWireInput {
        try #require(CanvasSurveyInputParser().parse(object(json)))
    }

    private func error(_ input: CanvasSurveyWireInput, _ values: [String]) -> String? {
        CanvasSurveyAnswerValidator().validationError(input: input, answer: SurveyAnswer(values: values))
    }

    // MARK: - Validator

    // Fails if: canvas_survey_answer_validator.swift `autoAdvanceEligible` lets a multi select or
    // a typed field advance on its own (the respondent could not pick a second option or finish
    // typing), or stops advancing a single choice or a scale.
    @Test("only a single choice or a scale may auto-advance", arguments: [
        ("single_select", true), ("upvote", true), ("multi_select", false),
        ("rating", true), ("reaction", true), ("nps", true),
        ("short_text", false), ("long_text", false), ("number", false), ("email", false), ("date", false),
    ])
    func autoAdvanceEligibility(type: String, eligible: Bool) throws {
        let input = try input(#"{ "type": "\#(type)", "required": true }"#)
        #expect(CanvasSurveyAnswerValidator().autoAdvanceEligible(input: input) == eligible)
        #expect(CanvasSurveyAnswerValidator().autoAdvanceEligible(input: nil) == false)
    }

    // Fails if: canvas_survey_answer_validator.swift `scaleValidationError` stops checking the
    // value against `minimum...maximum` (inclusive), or accepts a value that is not a number.
    @Test("a scale answer must be a number inside its range, ends included")
    func scaleRange() throws {
        let nps = try input(#"{ "type": "numeric_nps", "required": true, "minimum": 0, "maximum": 10 }"#)
        #expect(error(nps, ["0"]) == nil)
        #expect(error(nps, ["10"]) == nil)
        #expect(error(nps, [" 7 "]) == nil)
        #expect(error(nps, ["11"]) == "Choose a rating")
        #expect(error(nps, ["-1"]) == "Choose a rating")
        #expect(error(nps, ["great"]) == "Choose a rating")
    }

    // Fails if: canvas_survey_answer_validator.swift `fieldValidationError` stops trimming before
    // the required check (spaces would count as an answer).
    @Test("a required field answered with only spaces is still missing")
    func blankFieldIsMissing() throws {
        let text = try input(#"{ "type": "short_text", "required": true }"#)
        #expect(error(text, ["   "]) == "This field is required")
        #expect(error(text, ["a"]) == nil)
    }

    // Fails if: canvas_survey_answer_validator.swift `formatNumber` stops printing a fractional
    // bound as it is (it would read "Must be at least 1").
    @Test("a fractional number bound is quoted exactly; a whole one without decimals")
    func numberBoundFormatting() throws {
        let number = try input(#"{ "type": "number", "required": true, "min": 1.5, "max": 10 }"#)
        #expect(error(number, ["1.4"]) == "Must be at least 1.5")
        #expect(error(number, ["10.5"]) == "Must be at most 10")
        #expect(error(number, ["1.5"]) == nil)
    }

    // Fails if: canvas_survey_answer_validator.swift stops re-checking a choice answer against the
    // cap (an answer kept from before the cap applied would pass), or `optionWord` stops using the
    // singular.
    @Test("a choice answer over its cap is refused, in the singular for a cap of one")
    func choiceOverCap() throws {
        let capOne = try input(#"{ "type": "multi_select", "required": true, "maxSelections": 1, "options": [] }"#)
        #expect(error(capOne, ["a", "b"]) == "Select at most 1 option")
        let capTwo = try input(#"{ "type": "multi_select", "required": true, "validation": { "max_selection": 2 } }"#)
        #expect(error(capTwo, ["a", "b", "c"]) == "Select at most 2 options")
        #expect(error(capTwo, ["a", "b"]) == nil)
    }

    // Fails if: canvas_survey_answer_validator.swift `guard let input, input.required` starts
    // checking optional inputs (an optional question could then block Next).
    @Test("an optional input, or a scene with no input, is never refused")
    func optionalNeverRefused() throws {
        let optional = try input(#"{ "type": "email", "required": false }"#)
        #expect(error(optional, ["not-an-email"]) == nil)
        #expect(error(optional, []) == nil)
        #expect(CanvasSurveyAnswerValidator().validationError(input: nil, answer: nil) == nil)
    }

    // MARK: - Input parser

    // Fails if: canvas_survey_input_parser.swift `inputType` drops an alias the dashboard writes
    // (the question would silently become a single select).
    @Test("authored type aliases map to their input kind", arguments: [
        ("multiple_choice", CanvasSurveyInputType.multiSelect), ("multi", .multiSelect),
        ("Long-Text", .longText), ("shortText", .shortText), ("nps", .numericNps),
        ("numeric-nps", .numericNps), ("something_new", .singleSelect),
    ])
    func typeAliases(raw: String, type: CanvasSurveyInputType) throws {
        #expect(try input(#"{ "type": "\#(raw)" }"#).type == type)
        // `inputType` is read when `type` is absent.
        #expect(try input(#"{ "inputType": "\#(raw)" }"#).type == type)
    }

    // Fails if: canvas_survey_input_parser.swift `maxSelections` stops looking inside the nested
    // limit containers, or stops clamping the cap to 1...100.
    @Test("a selection cap is read under any of its spellings and nested containers, and clamped")
    func selectionCap() throws {
        func cap(_ json: String) throws -> Int? {
            guard case .choice(let choice) = try input(json) else { return -1 }
            return choice.maximumSelections
        }
        #expect(try cap(#"{ "type": "multi", "maximumSelections": 3 }"#) == 3)
        #expect(try cap(#"{ "type": "multi", "constraints": { "Max-Selection": 2 } }"#) == 2)
        #expect(try cap(#"{ "type": "multi", "rules": { "maxselection": 0 } }"#) == 1)
        #expect(try cap(#"{ "type": "multi", "limits": { "maxSelections": 500 } }"#) == 100)
        #expect(try cap(#"{ "type": "multi" }"#) == nil)
    }

    // Fails if: canvas_survey_input_parser.swift stops falling back to the scene kind for
    // `required` (a question scene without the flag would become optional).
    @Test("a question without a required flag takes the scene's fallback")
    func requiredFallback() throws {
        let raw = try object(#"{ "type": "short_text" }"#)
        #expect(CanvasSurveyInputParser().parse(raw, requiredFallback: true)?.required == true)
        #expect(CanvasSurveyInputParser().parse(raw)?.required == false)
        #expect(CanvasSurveyInputParser().parse(nil) == nil)
    }

    // MARK: - Document parser

    // Fails if: canvas_survey_document_parser.swift `documentCanvas` stops reading a scene whose
    // canvas is written inline rather than under `canvas`, or the parser stops defaulting the
    // height to 420 and the width to the design width.
    @Test("a scene canvas is read nested or inline, with missing sizes defaulted")
    func documentShapes() throws {
        let parser = CanvasSurveyDocumentParser()
        let nested = try parser.parse(object(#"{ "canvas": { "canvasWidth": 300, "canvasHeight": 500, "children": [] } }"#),
                                      fallbackDesignWidth: 360)
        #expect(nested.canvas.width == 300)
        #expect(nested.canvas.height == 500)
        let inline = try parser.parse(object(#"{ "children": [] }"#), fallbackDesignWidth: 320)
        #expect(inline.canvas.width == 320)
        #expect(inline.canvas.height == 420)
    }

    // Fails if: canvas_survey_document_parser.swift stops degrading an absent or unreadable
    // canvas to an empty stage (the survey would fail to parse instead of showing the scene
    // without it), or `empty` stops falling back to a 360 wide stage.
    @Test("an absent or unreadable canvas degrades to an empty stage")
    func unreadableCanvasDegrades() throws {
        let parser = CanvasSurveyDocumentParser()
        let absent = try parser.parse(nil, fallbackDesignWidth: 0)
        #expect(absent.canvas.width == 360)
        #expect(absent.canvas.height == 420)
        #expect(absent.canvas.children.isEmpty)
        #expect(absent.hosts.isEmpty)

        let unrelated = try parser.parse(object(#"{ "title": "no canvas here" }"#), fallbackDesignWidth: 400)
        #expect(unrelated.canvas.width == 400)

        // A canvas version this SDK does not read (older than 2) fails to parse.
        let broken = try parser.parse(object(#"{ "version": 1, "canvasWidth": 300, "children": [] }"#),
                                      fallbackDesignWidth: 380)
        #expect(broken.canvas.width == 380)
        #expect(broken.canvas.children.isEmpty)
    }

    // Fails if: canvas_survey_host_elements.swift stops dropping a host element of an unknown type
    // or a managed host with an unknown role (it would be drawn as something it is not).
    @Test("unknown host elements and managed roles are skipped; known ones are kept")
    func unknownHostsSkipped() throws {
        let document = try CanvasSurveyDocumentParser().parse(object("""
        { "canvasWidth": 360, "canvasHeight": 600, "children": [
          { "kind": "hostElement", "id": "future", "rect": { "x": 0, "y": 0, "width": 1, "height": 0.1 },
            "element": { "type": "canvasSurvey.somethingNew", "props": {} } },
          { "kind": "hostElement", "id": "odd_role", "rect": { "x": 0, "y": 0, "width": 1, "height": 0.1 },
            "element": { "type": "canvasSurvey.managed", "props": { "role": "confetti" } } },
          { "kind": "hostElement", "id": "count", "rect": { "x": 0.5, "y": 0.5, "width": 0.5, "height": 0.1 },
            "element": { "type": "canvasSurvey.managed", "props": { "role": "pageCount" } } },
          { "kind": "hostElement", "id": "answer", "rect": { "x": 0, "y": 0.2, "width": 1, "height": 0.5 },
            "element": { "type": "canvasSurvey.answerInput" } }
        ] }
        """), fallbackDesignWidth: 360)
        #expect(document.hosts.count == 2)
        #expect(document.managedHosts.map(\.id) == ["count"])
        #expect(document.managedHosts.first?.role == .pageCount)
        // Fractions of the canvas become points.
        #expect(document.managedHosts.first?.rect == CampaignCanvasRect(x: 180, y: 300, width: 180, height: 60))
    }

    // Fails if: canvas_survey_host_elements.swift `normalizedAction` stops giving a navigation
    // button without `onClick` its role's step: the canvas renders an action-less button as
    // inert, so Next or Back would do nothing.
    @Test("a navigation button authored without onClick gets its role's step", arguments: [
        ("primaryNavigation", EngageAction.next), ("backNavigation", .previous),
    ])
    func navigationButtonDefaultsItsAction(role: String, action: EngageAction) throws {
        let document = try CanvasSurveyDocumentParser().parse(object("""
        { "canvasWidth": 360, "canvasHeight": 600, "children": [
          { "kind": "hostElement", "id": "nav", "rect": { "x": 0, "y": 0.9, "width": 1, "height": 0.08 },
            "element": { "type": "canvasSurvey.managed", "props": { "role": "\(role)",
              "button": { "id": "btn", "props": { "label": { "spans": [ { "text": "Go" } ] }, "onClick": [] } } } } }
        ] }
        """), fallbackDesignWidth: 360)
        let button = try #require(document.managedHosts.first?.button)
        guard case .button(_, _, _, _, _, _, _, _, let actions, _) = button else {
            Issue.record("not a button: \(button)")
            return
        }
        #expect(actions == [action])
    }
}
