import XCTest
@testable import DigiaEngage

final class DigiaEndpointRegistryTests: XCTestCase {
    override func tearDown() {
        DigiaEndpoints.resetForTest()
        super.tearDown()
    }

    func testMockServerWinsOverEnvironmentAndTrimsTrailingSlash() throws {
        try DigiaTestKit.useMockServer("http://127.0.0.1:9871/", allowInRelease: true)
        DigiaEndpoints.configure(DigiaConfig(apiKey: "test", environment: .sandbox))

        XCTAssertEqual(
            DigiaEndpoints.campaigns,
            "http://127.0.0.1:9871/api/v1/engage/sdk/getCampaigns"
        )
    }

    func testMockServerCannotChangeAfterInitialization() throws {
        DigiaEndpoints.configure(DigiaConfig(apiKey: "test", environment: .sandbox))
        XCTAssertThrowsError(
            try DigiaTestKit.useMockServer("http://127.0.0.1:9871", allowInRelease: true)
        ) { error in
            XCTAssertEqual(error as? DigiaTestKitError, .alreadyInitialized)
        }
    }

    func testMockServerRequiresOriginWithoutURLSuffixes() {
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
            "https://example.com:",
        ]

        for root in invalidRoots {
            XCTAssertThrowsError(
                try DigiaTestKit.useMockServer(root, allowInRelease: true)
            )
        }
    }
}
