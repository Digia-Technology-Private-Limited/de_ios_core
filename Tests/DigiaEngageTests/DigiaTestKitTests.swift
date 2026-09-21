import Foundation
import Testing
@testable import DigiaEngage

@Suite("DigiaTestKit", .serialized)
struct DigiaTestKitTests {

    init() {
        DigiaTestKit.resetForTest()
    }

    @Test("overrideBaseUrl updates endpoints and trims trailing slash")
    func overrideBaseUrlUpdatesEndpoints() throws {
        try DigiaTestKit.overrideBaseUrl("http://10.0.2.2:9871/")
        DigiaEndpoints.configure(DigiaConfig(apiKey: "test", environment: .sandbox))

        #expect(DigiaEndpoints.campaignBundle == "http://10.0.2.2:9871/api/v1/engage/sdk/getCampaignBundle")
        #expect(DigiaEndpoints.track == "http://10.0.2.2:9871/api/v1/engage/sdk/track")
    }

    @Test("overrideBaseUrl cannot be called after initialization")
    func overrideBaseUrlFailsAfterInit() {
        DigiaEndpoints.configure(DigiaConfig(apiKey: "test", environment: .sandbox))

        #expect(throws: DigiaTestKit.Error.alreadyInitialized) {
            try DigiaTestKit.overrideBaseUrl("http://localhost:9871")
        }
    }

    @Test("overrideBaseUrl rejects invalid roots")
    func overrideBaseUrlRejectsInvalidRoots() {
        let invalidRoots = [
            "localhost:9871",
            "file:///tmp/mock-server",
            "https://user@example.com",
            "https://@example.com",
            "https://example.com/api",
            "https://example.com///",
            "https://example.com?fixture=nudge",
            "https://example.com?",
            "https://example.com#fragment",
            "https://example.com#",
            "https://example.com:"
        ]

        for root in invalidRoots {
            #expect(throws: DigiaTestKit.Error.invalidRootUrl(root)) {
                try DigiaTestKit.overrideBaseUrl(root)
            }
        }
    }

    @Test("resetForTest restores production default and clears initialization flag")
    func resetForTestRestoresDefaults() throws {
        try DigiaTestKit.overrideBaseUrl("http://10.0.2.2:9871")
        DigiaEndpoints.configure(DigiaConfig(apiKey: "test"))

        DigiaTestKit.resetForTest()

        #expect(DigiaEndpoints.campaignBundle == "https://app.digia.tech/api/v1/engage/sdk/getCampaignBundle")

        // Should be able to override again after reset
        try DigiaTestKit.overrideBaseUrl("http://127.0.0.1:8080")
        #expect(DigiaEndpoints.campaignBundle == "http://127.0.0.1:8080/api/v1/engage/sdk/getCampaignBundle")
    }
}
