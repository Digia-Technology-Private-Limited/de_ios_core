import Foundation
import Testing
@testable import DigiaEngage

@Suite("Canvas Survey config")
struct CanvasSurveyConfigTests {
    @Test("keeps answer host presentation metadata")
    func answerHostPresentation() throws {
        let survey = try #require(CanvasSurveyConfigParser.from(
            parseCanvasSurveyTemplate(),
            fallbackId: "fallback"
        ))
        let document = try #require(survey.canvasSurvey?.scenesByBlockId["scene_single_select"])
        guard case .answer(let answer) = document.canvasHosts.first else {
            Issue.record("Expected answer host")
            return
        }
        guard case .choice(let input) = document.input else {
            Issue.record("Expected choice input")
            return
        }

        #expect(input.type == .singleSelect)
        #expect(input.options.map(\.id) == ["yes", "no"])
        #expect(answer.presentationStyle.layout == .grid)
        #expect(answer.presentationStyle.fontWeight == 600)
        #expect(answer.presentationStyle.textColor.lightHex == "#FF334155")
    }

    @Test("keeps shared answer text style when dashboard template text is empty")
    func sharedAnswerStyleWithoutTemplateText() throws {
        let survey = try #require(CanvasSurveyConfigParser.from(
            parseCanvasSurveyTemplate(
                scenes: [
                    questionScene(
                        type: "single_select",
                        sharedTextJson: """
                        "text": {
                          "spans": [
                            {
                              "text": "",
                              "typography": { "value": { "fontSize": 14, "fontWeight": 500 } },
                              "color": { "value": "#1818FF" }
                            }
                          ]
                        },
                        "optionStyleMode": "shared",
                        """
                    )
                ]
            ),
            fallbackId: "fallback"
        ))
        let document = try #require(survey.canvasSurvey?.scenesByBlockId["scene_single_select"])
        guard case .answer(let answer) = document.canvasHosts.first else {
            Issue.record("Expected answer host")
            return
        }

        #expect(answer.sharedText?.text == "")
        #expect(answer.sharedText?.typography.fontSize == 14)
        #expect(answer.sharedText?.typography.fontWeight == 500)
        #expect(answer.sharedText?.color?.lightHex == "#FF1818FF")
    }

    @Test("parses heavy answer input font weight")
    func heavyAnswerHostWeight() throws {
        let survey = try #require(CanvasSurveyConfigParser.from(
            parseCanvasSurveyTemplate(fontWeight: "heavy"),
            fallbackId: "fallback"
        ))
        let document = try #require(survey.canvasSurvey?.scenesByBlockId["scene_single_select"])
        guard case .answer(let answer) = document.canvasHosts.first else {
            Issue.record("Expected answer host")
            return
        }

        #expect(answer.presentationStyle.fontWeight == 900)
    }

    @Test("maps shared ui controls into active canvas height")
    func sharedUiOverlayGeometry() throws {
        let survey = try #require(CanvasSurveyConfigParser.from(
            parseCanvasSurveyTemplate(welcomeEnabled: false, bodyHeight: 320, includeBack: true),
            fallbackId: "fallback"
        ))
        let hosts = try #require(survey.canvasSurvey?.scenesByBlockId["scene_single_select"]?.sharedUiHosts)

        #expect(hosts.map(\.role) == [.primaryNavigation])
        #expect(abs((hosts.first?.rect.x ?? 0) - 20) < 0.01)
        #expect(abs((hosts.first?.rect.y ?? 0) - 240) < 0.01)
        #expect(abs((hosts.first?.rect.width ?? 0) - 320) < 0.01)

        let document = try #require(survey.canvasSurvey?.scenesByBlockId["scene_single_select"])
        guard case .solid(let background) = document.sharedUi.background else {
            Issue.record("Expected shared UI background to be preserved")
            return
        }
        #expect(background.lightHex == "#FF102030")
    }

    @Test("progress counts only reachable question scenes by default")
    @MainActor
    func progressCountsQuestionScenes() throws {
        let template = try parseCanvasSurveyTemplate(
            welcomeEnabled: false,
            scenes: [
                contentScene(id: "intro_content", title: "Content screen", kind: "content"),
                questionScene(type: "single_select"),
                questionScene(type: "multi_select"),
                contentScene(id: "thank_you_result", title: "Thank you", kind: "result")
            ],
            flowNodes: [
                flowNode(id: "node_intro_content", sceneId: "intro_content", target: "node_single_select"),
                flowNode(id: "node_single_select", sceneId: "scene_single_select", target: "node_multi_select"),
                flowNode(id: "node_multi_select", sceneId: "scene_multi_select", target: "node_thank_you_result"),
                flowNode(id: "node_thank_you_result", sceneId: "thank_you_result", target: nil)
            ],
            rootNodeId: "node_intro_content"
        )
        let survey = try #require(CanvasSurveyConfigParser.from(template, fallbackId: "fallback"))
        let vm = SurveyViewModel(survey: survey)

        #expect(vm.progressTotal(countQuestionsOnly: true) == 2)
        #expect(vm.progressCurrent(countQuestionsOnly: true) == 1)
        #expect(vm.progressTotal(countQuestionsOnly: false) == 4)
    }

    @Test("canvas survey campaign start builds variable context")
    @MainActor
    func canvasSurveyStartBuildsVariableContext() throws {
        let data = Data(canvasSurveyTemplate(
            welcomeEnabled: true,
            bodyHeight: 640,
            includeBack: false,
            fontWeight: "semibold",
            scenes: nil,
            flowNodes: nil,
            rootNodeId: "node_single_select"
        ).utf8)
        var template = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        template["variables"] = [
            ["name": "first_name", "fallbackValue": "there"],
            ["name": "score", "type": "number", "fallbackValue": "7"]
        ]
        let campaign = try #require(CampaignModel.fromJson([
            "id": "campaign1",
            "campaignKey": "canvas_survey",
            "campaignType": "survey",
            "templateConfig": template
        ]))
        let survey = try #require(campaign.surveyConfig)
        let orchestrator = SurveyOrchestrator()

        let started = orchestrator.start(
            payload: CEPTriggerPayload(
                cepCampaignId: "cep1",
                campaignKey: "canvas_survey",
                cepMetadata: [:],
                variables: ["first_name": "Asha"]
            ),
            config: survey
        )

        #expect(started)
        let variables = try #require(orchestrator.state?.variableContext)
        #expect(variables.values["first_name"] == "Asha")
        #expect(variables.values["score"] == "7")
        #expect(interpolate("Hi {{first_name}}, score {{score + 1}}", context: variables) == "Hi Asha, score 8")
    }

    private func parseCanvasSurveyTemplate(
        welcomeEnabled: Bool = true,
        bodyHeight: Int = 640,
        includeBack: Bool = false,
        fontWeight: String = "semibold",
        scenes: [String]? = nil,
        flowNodes: [String]? = nil,
        rootNodeId: String = "node_single_select"
    ) throws -> [String: JSONValue] {
        let data = Data(canvasSurveyTemplate(
            welcomeEnabled: welcomeEnabled,
            bodyHeight: bodyHeight,
            includeBack: includeBack,
            fontWeight: fontWeight,
            scenes: scenes,
            flowNodes: flowNodes,
            rootNodeId: rootNodeId
        ).utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = value else {
            throw TestError.invalidFixture
        }
        return object
    }

    private func canvasSurveyTemplate(
        welcomeEnabled: Bool,
        bodyHeight: Int,
        includeBack: Bool,
        fontWeight: String,
        scenes: [String]?,
        flowNodes: [String]?,
        rootNodeId: String
    ) -> String {
        let sceneJson = scenes?.joined(separator: ",") ?? questionScene(type: "single_select", bodyHeight: bodyHeight, fontWeight: fontWeight)
        let flowJson = flowNodes?.joined(separator: ",") ?? flowNode(id: "node_single_select", sceneId: "scene_single_select", target: nil)
        let backHost = includeBack
            ? """
            ,
            {
              "kind": "hostElement",
              "id": "back_shared",
              "rect": { "x": 0.0555556, "y": 0.875, "width": 0.3, "height": 0.075 },
              "element": {
                "type": "canvasSurvey.managed",
                "props": { "role": "backNavigation", "label": "Back" }
              }
            }
            """
            : ""
        return """
        {
          "templateType": "survey",
          "layoutMode": "canvas",
          "schemaVersion": 1,
          "display": { "type": "dialog", "cornerRadius": 18 },
          "behavior": { "autoAdvance": true },
          "welcome": {
            "enabled": \(welcomeEnabled),
            "canvas": {
              "version": 2,
              "canvasWidth": 360,
              "canvasHeight": 640,
              "children": []
            }
          },
          "sharedUi": {
            "canvas": {
              "version": 2,
              "canvasWidth": 360,
              "canvasHeight": 640,
              "background": { "type": "solid", "color": "#102030" },
              "children": [
                {
                  "kind": "hostElement",
                  "id": "primary_nav_shared",
                  "rect": { "x": 0.0555556, "y": 0.875, "width": 0.8888889, "height": 0.075 },
                  "element": {
                    "type": "canvasSurvey.managed",
                    "props": {
                      "role": "primaryNavigation",
                      "label": "Next",
                      "doneLabel": "Done",
                      "fill": "#4945FF",
                      "color": "#FFFFFF",
                      "cornerRadius": 12,
                      "fontSize": 15
                    }
                  }
                }
                \(backHost)
              ]
            }
          },
          "scenes": [\(sceneJson)],
          "flow": {
            "rootNodeId": "\(rootNodeId)",
            "nodes": [\(flowJson)]
          }
        }
        """
    }

    private func questionScene(
        type: String,
        bodyHeight: Int = 640,
        fontWeight: String = "semibold",
        sharedTextJson: String = ""
    ) -> String {
        """
        {
          "id": "scene_\(type)",
          "kind": "question",
          "enabled": true,
          "title": "\(type)",
          "roles": { "prompt": "prompt_\(type)", "answerInput": "answer_\(type)" },
          "input": {
            "profile": "choice",
            "type": "\(type)",
            "required": true,
            "options": [
              { "id": "yes", "label": "Yes" },
              { "id": "no", "label": "No" }
            ]
          },
          "canvas": {
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": \(bodyHeight),
            "children": [
              {
                "kind": "hostElement",
                "id": "answer_\(type)",
                "rect": { "x": 0.0555556, "y": 0.41875, "width": 0.8888889, "height": 0.28125 },
                "element": {
                  "type": "canvasSurvey.answerInput",
                  "props": {
                    \(sharedTextJson)
                    "style": {
                      "layout": "grid",
                      "fontSize": 15,
                      "fontWeight": "\(fontWeight)",
                      "textColor": "#334155"
                    }
                  }
                }
              }
            ]
          }
        }
        """
    }

    private func contentScene(id: String, title: String, kind: String) -> String {
        """
        {
          "id": "\(id)",
          "kind": "\(kind)",
          "enabled": true,
          "title": "\(title)",
          "roles": {},
          "input": null,
          "canvas": {
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 240,
            "children": []
          },
          "sharedUi": {
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 240,
            "children": []
          }
        }
        """
    }

    private func flowNode(id: String, sceneId: String, target: String?) -> String {
        """
        {
          "id": "\(id)",
          "sceneId": "\(sceneId)",
          "rules": [],
          "fallback": \(target.map { "{ \"kind\": \"node\", \"nodeId\": \"\($0)\" }" } ?? "{ \"kind\": \"end\" }")
        }
        """
    }
}

private enum TestError: Error {
    case invalidFixture
}
