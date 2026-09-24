import Foundation
import Testing

@testable import DigiaEngage

/// Drives the real `initialize()` on an isolated `SDKInstance` (own defaults,
/// fake network), so nothing here races the shared instance other suites use.
@MainActor
@Suite("SDKInstance initialize", .serialized)
struct SDKInstanceInitTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
    }

    private func makeInstance(defaults: UserDefaults) -> SDKInstance {
        let network = MockNetworkClient()
        return SDKInstance(defaults: defaults, legacyDefaults: makeDefaults(), makeNetworkClient: { _ in network })
    }

    private func queuedEvents(_ sdk: SDKInstance) throws -> [[String: Any]] {
        let analytics = try #require(sdk.services?.analyticsService)
        return analytics.queue.peek(maxCount: 100).map(\.payload)
    }

    @Test("setUserId right after an un-awaited initialize() reaches the first tracked event")
    func setUserIdDuringInitialize() async throws {
        let sdk = makeInstance(defaults: makeDefaults())
        let initializing = Task { try await sdk.initialize(DigiaConfig(apiKey: "test_key")) }
        sdk.setUserId("u")
        try await initializing.value

        sdk.services?.analyticsService?.captureHealth(
            campaignKey: nil, reason: "probe", stage: nil, detail: nil, buildMode: "debug")

        let events = try queuedEvents(sdk)
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0["user_id"] as? String == "u" })
    }
}
