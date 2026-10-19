import Foundation
import Testing

@testable import DigiaEngage

@MainActor
@Suite("SDKServices unit tests", .serialized)
struct SDKServicesTests {

    private func makeServices() -> SDKServices {
        let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)
        return SDKServices(config: DigiaConfig(apiKey: "test_key"), storage: storage, networkClient: MockNetworkClient())
    }

    private func countRotations(_ services: SDKServices) -> () -> Int {
        var count = 0
        services.sessionManager.addRotationListener { count += 1 }
        return { count }
    }

    @Test("setting the same user ID twice rotates the session once")
    func sameUserIdRotatesOnce() {
        let services = makeServices()
        let rotations = countRotations(services)

        services.identityManager.setUserId("u1")
        services.identityManager.setUserId("u1")
        services.identityManager.setUserId("  u1 ")

        #expect(rotations() == 1)
    }

    @Test("clearing while anonymous does not rotate; clearing a user does")
    func clearRotatesOnlyFromAUser() {
        let services = makeServices()
        let rotations = countRotations(services)

        services.identityManager.clearUserId()
        #expect(rotations() == 0)

        services.identityManager.setUserId("u1")
        services.identityManager.clearUserId()
        #expect(rotations() == 2)
    }

    // Flutter: `test/sdk_services_test.dart` › flushAnalytics flushes both queues.
    @Test("flushAnalytics flushes both queues")
    func flushAnalyticsFlushesBothQueues() async throws {
        let client = MockNetworkClient()
        client.setResponseFactory { _ in
            NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
        }
        let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)
        let services = SDKServices(config: DigiaConfig(apiKey: "test_key"), storage: storage, networkClient: client)
        let experience = try #require(services.analyticsService)
        let appEvents = try #require(services.appEventsService)

        experience.capture(
            NudgeEvent.Viewed(displayStyle: "dialog"),
            payload: CEPTriggerPayload(cepCampaignId: "c", campaignKey: "c", cepMetadata: [:]),
            campaignId: "c", campaignType: "guide"
        )
        appEvents.track("add_to_cart")

        services.flushAnalytics()

        func bodies() -> [String] {
            client.recordedRequests
                .filter { $0.url.absoluteString == DigiaEndpoints.track }
                .map { $0.body.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        }
        for _ in 0..<500 where bodies().count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }

        // One request per queue — the owner reaches both, and neither queue knows the other exists.
        #expect(bodies().count == 2)
        #expect(bodies().contains { $0.contains("Digia Experience Viewed") })
        #expect(bodies().contains { $0.contains("add_to_cart") })
        services.tearDown()
    }
}
