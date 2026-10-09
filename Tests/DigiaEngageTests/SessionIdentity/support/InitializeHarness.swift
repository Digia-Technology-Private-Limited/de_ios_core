import Foundation

@testable import DigiaEngage

/// Runs the real `SDKInstance.initialize` over defaults that outlive one instance, so a test can
/// relaunch the app: each `launch()` is a new process over the same storage. Session reports go to
/// one `FakeNetworkClient` across launches; the session clock is a `TestClock`.
@MainActor
final class InitializeHarness {
    let defaults: UserDefaults
    let clock: TestClock
    let network = FakeNetworkClient()
    private(set) var sdk: SDKInstance!
    private var session: CurrentSessionRef!

    init(clock: TestClock = TestClock(10, 0)) {
        self.clock = clock
        defaults = UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
        // Marks storage as already migrated, so no launch runs the migrator (and its cleanup of
        // the real caches directory). There is no legacy data in these tests either way.
        defaults.set(1, forKey: "storage.version")
        launch()
    }

    /// A new process over the same storage. The previous instance is dropped.
    func launch() {
        let network = network
        var session: CurrentSessionRef?
        sdk = SDKInstance(
            defaults: defaults,
            legacyDefaults: UserDefaults(suiteName: "digia.test.legacy.\(UUID().uuidString)")!,
            makeNetworkClient: { ref in
                session = ref
                return network
            },
            clock: clock.closure
        )
        self.session = session
    }

    func initialize() async throws {
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
    }

    var services: SDKServices { sdk.services! }

    /// Waits for every report scheduled so far (the reporter runs its work in call order).
    func settle() async {
        await sdk.services?.sessionReporter.flush().value
    }

    /// Waits, without scheduling anything itself, until `count` reports were attempted or a
    /// second passed. For a test where `settle()`'s own flush would hide a missing one.
    func waitForAttempts(_ count: Int) async throws {
        for _ in 0..<100 where network.attempts.count < count {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A header as the production client assembles it, from the session `SDKInstance` publishes.
    func header(_ name: String) -> String? {
        let session = session!
        let client = URLSessionNetworkClient(
            sessionIdProvider: { session.sessionId },
            headerProvider: { session.requestHeaders }
        )
        return client.assembleHeaders(for: [:]).first { $0.key.lowercased() == name.lowercased() }?.value
    }

    // MARK: - Seeding storage as an earlier launch left it

    func seedSession(_ id: String, lastActivityMs: Int64) {
        defaults.set(id, forKey: "session.session_id")
        defaults.set(String(lastActivityMs), forKey: "session.last_activity_ms")
    }

    func seedUser(_ userId: String) {
        defaults.set(userId, forKey: "identity.user_id")
    }

    func seedDevice(_ deviceId: String) {
        defaults.set(deviceId, forKey: "identity.device_id")
    }

    /// Seeds the reporter's pending list with one report body per session.
    func seedPending(_ bodies: [[String: Any]]) {
        let list = bodies.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        let raw = String(data: try! JSONSerialization.data(withJSONObject: list), encoding: .utf8)!
        defaults.set(raw, forKey: "session.\(SessionReporter.keyPendingReport)")
    }
}
