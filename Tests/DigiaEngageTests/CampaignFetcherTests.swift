import Foundation
import Testing
@testable import DigiaEngage

@Suite("Campaign fetcher contract", .tags(.contract))
struct CampaignFetcherTests {

    @Test("bundle envelopes keep valid campaigns and drop malformed Canvas colors")
    func bundleIsolationPreservesValidAndRecoversMalformed() throws {
        let response: [String: Any] = [
            "data": ["response": [
                "campaigns": [canvasCampaign(key: "valid", color: "#112233"), canvasCampaign(key: "invalid", color: ["token": "missing"]), 42],
                "designTokens": [
                    "supportedThemes": ["light"],
                    "themes": ["light": ["colors": []]],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let bundle = try CampaignFetcher.parse(data)

        #expect(bundle.rawCampaigns.count == 2)
        #expect(bundle.campaigns.map(\.campaignKey) == ["valid", "invalid"])
    }

    @Test("bundle parser handles empty campaigns and rejects malformed envelopes")
    func bundleIsolationEnvelopesValidation() throws {
        #expect(try CampaignFetcher.parse(Data(#"{"response":{"campaigns":[]}}"#.utf8)).campaigns.isEmpty)
        #expect(try CampaignFetcher.parse(Data(#"{"campaigns":[]}"#.utf8)).campaigns.isEmpty)
        #expect(throws: CampaignFetchError.self) { try CampaignFetcher.parse(Data("[]".utf8)) }
        #expect(throws: CampaignFetchError.self) { try CampaignFetcher.parse(Data("{}".utf8)) }
    }

    @Test("sdkHealth and sdkHealthSessionCap are read defensively from the bundle")
    func healthConfigReadDefensively() throws {
        // Absent entirely: on, default cap.
        let absent = try CampaignFetcher.parse(Data(#"{"campaigns":[]}"#.utf8))
        #expect(absent.healthEnabled == true)
        #expect(absent.healthSessionCap == nil)

        // Explicit false, a real cap.
        let disabled = try CampaignFetcher.parse(
            Data(#"{"campaigns":[],"sdkHealth":false,"sdkHealthSessionCap":5}"#.utf8))
        #expect(disabled.healthEnabled == false)
        #expect(disabled.healthSessionCap == 5)

        // Garbage shapes must fall back to the defaults rather than trap.
        let garbage = try CampaignFetcher.parse(
            Data(#"{"campaigns":[],"sdkHealth":"nope","sdkHealthSessionCap":-3}"#.utf8))
        #expect(garbage.healthEnabled == true)
        #expect(garbage.healthSessionCap == nil)

        let garbageString = try CampaignFetcher.parse(
            Data(#"{"campaigns":[],"sdkHealthSessionCap":"not a number"}"#.utf8))
        #expect(garbageString.healthSessionCap == nil)

        // Explicit true is still on — only an explicit false stops it.
        let explicitTrue = try CampaignFetcher.parse(Data(#"{"campaigns":[],"sdkHealth":true}"#.utf8))
        #expect(explicitTrue.healthEnabled == true)
    }

    @Test("invalid token catalog degrades to literals only")
    func invalidCatalog() {
        let bundle = CampaignBundle.create(
            rawCampaigns: [canvasCampaign(key: "literal", color: "#123456")],
            designTokensJSON: ["supportedThemes": ["brand", "contrast"], "themes": [:]]
        )

        #expect(bundle.campaigns.map(\.campaignKey) == ["literal"])
    }

    private func canvasCampaign(key: String, color: Any) -> [String: Any] {
        [
            "id": key, "campaignKey": key, "campaignType": "nudge",
            "templateConfig": [
                "layoutMode": "canvas",
                "canvas": [
                    "version": 2, "canvasWidth": 360, "canvasHeight": 100,
                    "background": ["type": "solid", "color": "#fff"],
                    "children": [[
                        "kind": "widget", "id": "text",
                        "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
                        "widget": [
                            "type": "digia/text",
                            "props": ["spans": [["text": "Hi", "color": color]]],
                        ],
                    ]],
                ],
            ],
        ]
    }
}
