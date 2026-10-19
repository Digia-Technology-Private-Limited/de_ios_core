import Foundation
import Testing
@testable import DigiaEngage

/// Flutter: `test/campaign_fetcher_test.dart` (schema-version header) and the bundle
/// app-event upload settings read by `CampaignFetcher`.
@Suite("DMC campaign fetcher", .serialized)
struct DMCCampaignFetcherTests {
    @Test("the campaign fetch declares the campaign schema version it reads")
    func sendsSchemaVersionHeader() async throws {
        let client = MockNetworkClient()
        client.setResponseFactory { _ in
            NetworkResponse(
                statusCode: 200, headers: [:], body: Data(#"{"campaigns":[]}"#.utf8), isSuccessful: true)
        }

        _ = try await CampaignFetcher(networkClient: client).fetch()

        #expect(client.recordedRequests.count == 1)
        #expect(client.recordedRequests[0].headers["x-digia-campaign-schema-version"] == "2")
    }

    @Test("app event upload settings default to on and unlimited")
    func appEventPolicyDefaults() throws {
        let policy = try CampaignFetcher.parse(Data(#"{"campaigns":[]}"#.utf8)).appEventUploadPolicy
        #expect(policy.enabled)
        #expect(policy.ratePerMinute == 0)
        #expect(policy.burst == 0)
        #expect(policy.blockedNames.isEmpty)
    }

    @Test("app event upload settings are read from the bundle")
    func appEventPolicyRead() throws {
        let json = #"""
        {"campaigns":[],"appEventUpload":false,"appEventRatePerMinute":30,"appEventBurst":5,
         "appEventBlockedNames":["secret","other",7]}
        """#
        let policy = try CampaignFetcher.parse(Data(json.utf8)).appEventUploadPolicy
        #expect(!policy.enabled)
        #expect(policy.ratePerMinute == 30)
        #expect(policy.burst == 5)
        #expect(policy.blockedNames == ["secret", "other"])
    }

    @Test("malformed app event upload settings fall back to the defaults")
    func appEventPolicyGarbage() throws {
        let json = #"""
        {"campaigns":[],"appEventUpload":"no","appEventRatePerMinute":-4,"appEventBurst":"x",
         "appEventBlockedNames":"secret"}
        """#
        let policy = try CampaignFetcher.parse(Data(json.utf8)).appEventUploadPolicy
        #expect(policy.enabled)
        #expect(policy.ratePerMinute == 0)
        #expect(policy.burst == 0)
        #expect(policy.blockedNames.isEmpty)
    }
}
