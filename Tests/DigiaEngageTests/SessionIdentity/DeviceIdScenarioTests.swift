import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.7: device ID.
/// Left out on iOS: S36 (the ANDROID_ID check is Android-only; iOS's source choice is
/// `identifierForVendor`, reachable only through UIDevice), S37 (a platform difference, not a unit
/// test, per the scenarios doc) and S38 (iOS has no public device ID getter).
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

    // Left out: every event's anonymous_id (AnalyticsService is main-actor) and the OS-update case.
    func test_S35_theDeviceIdNeverChangesAndIsTheSameEverywhereItIsSent() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0), deviceId: "D1")
        h.identity.setUserId("asha")
        h.identity.clearUserId()
        h.identity.setUserId("ravi")
        h.session.reset()
        h.session.reset()
        h.session.reset()
        await h.settle()
        XCTAssertEqual(h.identity.deviceId, "D1")

        // A retried initialize or an app update: a new graph over the same storage.
        let relaunch = SessionIdentityHarness(storage: h.storage, clock: h.clock, network: h.network, deviceId: "D9")
        XCTAssertEqual(relaunch.identity.deviceId, "D1")
        relaunch.session.reset()
        await relaunch.settle()

        XCTAssertEqual(Set(h.network.attempts.map(\.anonymousId)), ["D1"], "session reports' anonymous_id")
        let headers = SDKRequestHeaders.make(config: DigiaConfig(apiKey: "key"), deviceId: relaunch.identity.deviceId)
        XCTAssertEqual(headers["X-Digia-Device-Id"], "D1")
    }
}
