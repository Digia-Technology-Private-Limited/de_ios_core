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
}
