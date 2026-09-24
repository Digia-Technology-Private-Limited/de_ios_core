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

    @Test("cold start keeps the persisted device ID and resumes a recent session")
    func coldStartKeepsIdentityAndSession() async throws {
        let defaults = makeDefaults()
        let tenMinutesAgoMs = Int64(Date().timeIntervalSince1970 * 1000) - 10 * 60 * 1000
        defaults.set(1, forKey: "storage.version")
        defaults.set("REAL-DEVICE-ID", forKey: "identity.device_id")
        defaults.set("persisted-session", forKey: "session.session_id")
        defaults.set(String(tenMinutesAgoMs), forKey: "session.last_activity_ms")

        let sdk = makeInstance(defaults: defaults)
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))

        let services = try #require(sdk.services)
        #expect(services.identityManager.deviceId == "REAL-DEVICE-ID")
        #expect(defaults.string(forKey: "identity.device_id") == "REAL-DEVICE-ID")
        #expect(services.sessionManager.sessionId == "persisted-session")
        #expect(services.sessionManager.resumedAtStartup)
    }
}

