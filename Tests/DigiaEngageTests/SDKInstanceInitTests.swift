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

    private func makeInstance(
        defaults: UserDefaults,
        network: MockNetworkClient = MockNetworkClient()
    ) -> SDKInstance {
        SDKInstance(defaults: defaults, legacyDefaults: makeDefaults(), makeNetworkClient: { _ in network })
    }

    /// Session reports are posted from a detached task; waits for them to land.
    private func sessionPosts(_ network: MockNetworkClient, atLeast count: Int) async throws -> Int {
        func posts() -> Int {
            network.recordedRequests.filter { $0.url.absoluteString.hasSuffix("/engage/sdk/session") }.count
        }
        for _ in 0..<100 where posts() < count {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        return posts()
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

    @Test("a user ID buffered before initialize() rotates the session exactly once")
    func bufferedSetUserIdRotatesOnce() async throws {
        let network = MockNetworkClient()
        let sdk = makeInstance(defaults: makeDefaults(), network: network)
        sdk.setUserId("u")
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))

        // One report for the new startup session, one for the rotation.
        #expect(try await sessionPosts(network, atLeast: 2) == 2)
        #expect(sdk.services?.identityManager.userId == "u")
    }
}
