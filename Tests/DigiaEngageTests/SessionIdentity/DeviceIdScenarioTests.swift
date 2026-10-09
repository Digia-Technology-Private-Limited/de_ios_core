import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.7: device ID.
/// Left out on iOS: S36 (the ANDROID_ID check is Android-only; iOS's source choice is
/// `identifierForVendor`, reachable only through UIDevice), S37 (a platform difference, not a unit
/// test, per the scenarios doc). S38 is in `PreInitializeCallScenarioTests`.
final class DeviceIdScenarioTests: XCTestCase {

    func test_S34_aDeviceIdIsCreatedOnceAndReadFromStorageAfterThat() {
        let storage = InMemoryLocalStorage()
        let generated = SessionIdBox("")
        let first = IdentityManager(storage: storage.scoped("identity"), idGenerator: { generated.value += "1"; return "D1" })
        XCTAssertEqual(first.deviceId, "D1")
        XCTAssertEqual(storage.string(forKey: "identity.device_id"), "D1")

        let tomorrow = IdentityManager(storage: storage.scoped("identity"), idGenerator: { generated.value += "2"; return "D2" })
        XCTAssertEqual(tomorrow.deviceId, "D1")
        XCTAssertEqual(generated.value, "1", "the generator ran once, on the first launch")
    }

    // The app update is a relaunch over the same storage: iOS reads the app version from the
    // bundle, so a test can't change it.
    @MainActor
    func test_S35_theDeviceIdNeverChangesAndIsTheSameEverywhereItIsSent() async throws {
        let h = InitializeHarness(clock: TestClock(10, 0))
        try await h.initialize()
        let d1 = h.services.identityManager.deviceId
        XCTAssertFalse(d1.isEmpty)

        h.sdk.setUserId("asha")
        h.sdk.clearUserId()
        h.sdk.setUserId("ravi")
        h.services.sessionManager.reset()
        h.services.sessionManager.reset()
        h.services.sessionManager.reset()
        try await h.initialize()                // a retried initialize
        h.services.analyticsService?.captureHealth(
            campaignKey: nil, reason: "probe", stage: nil, detail: nil, buildMode: "debug")
        await h.settle()
        XCTAssertEqual(h.header("X-Digia-Device-Id"), d1)

        h.clock.set(10, 1)                      // an app update: a new process over the same storage
        h.launch()
        try await h.initialize()
        h.sdk.setUserId("asha")
        h.services.analyticsService?.captureHealth(
            campaignKey: nil, reason: "probe", stage: nil, detail: nil, buildMode: "debug")
        await h.settle()

        XCTAssertEqual(h.services.identityManager.deviceId, d1)
        XCTAssertEqual(h.header("X-Digia-Device-Id"), d1)
        XCTAssertEqual(h.network.attempts.count, 8, "seven in the first process, one for the login after the update")
        XCTAssertEqual(Set(h.network.attempts.map(\.anonymousId)), [d1], "session reports' anonymous_id")
        let events = try XCTUnwrap(h.services.analyticsService).queue.peek(maxCount: 1000).map(\.payload)
        let probes = events.filter { ($0["properties"] as? [String: Any])?["reason"] as? String == "probe" }
        XCTAssertEqual(probes.count, 2, "both processes' probe events are in the checked set")
        XCTAssertEqual(Set(events.map { $0["anonymous_id"] as? String }), [d1], "every event's anonymous_id")
    }
}
