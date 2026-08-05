import XCTest
@testable import DigiaEngage

final class DigiaEndpointRegistryTests: XCTestCase {
    override func tearDown() {
        DigiaTestKit.clearMockServer()
        DigiaEndpoints.resetForTest()
        super.tearDown()
    }

    func testMockServerWinsOverEnvironmentAndTrimsTrailingSlash() throws {
        try DigiaTestKit.useMockServer("http://127.0.0.1:9871/")
        DigiaEndpoints.configure(DigiaConfig(apiKey: "test", environment: .sandbox))

        XCTAssertEqual(
            DigiaEndpoints.campaigns,
            "http://127.0.0.1:9871/api/v1/engage/sdk/getCampaigns"
        )
    }

    func testClearingMockServerRestoresConfiguredEnvironment() throws {
        DigiaEndpoints.configure(DigiaConfig(apiKey: "test", environment: .sandbox))
        try DigiaTestKit.useMockServer("http://127.0.0.1:9871")

        DigiaTestKit.clearMockServer()

        XCTAssertEqual(
            DigiaEndpoints.campaigns,
            "https://dev.digia.tech/api/v1/engage/sdk/getCampaigns"
        )
    }

    func testMockServerRequiresAbsoluteHTTPURL() {
        XCTAssertThrowsError(
            try DigiaTestKit.useMockServer("file:///tmp/mock-server")
        )
    }
}
