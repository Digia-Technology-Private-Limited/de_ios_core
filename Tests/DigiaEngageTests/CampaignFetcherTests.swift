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
