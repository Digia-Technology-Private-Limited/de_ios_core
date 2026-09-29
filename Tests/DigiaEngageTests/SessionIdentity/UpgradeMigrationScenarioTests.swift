import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.9: the first launch after an SDK upgrade. The migrator runs over two
/// `MigrationStore` fakes with UserDefaults' type rules; the managers then read the target store
/// through `InMemoryLocalStorage` over the same values, as production does with one suite.
final class UpgradeMigrationScenarioTests: XCTestCase {

    private let target = StorageBacking()
    private let legacy = StorageBacking()
    private lazy var targetStore = FakeMigrationStore(target)
    private lazy var legacyStore = FakeMigrationStore(legacy)

    private func migrate() {
        LocalStorageMigrator.migrateIfNeeded(targetDefaults: targetStore, standardDefaults: legacyStore)
    }

    private func launch(clock: TestClock = TestClock(10, 0)) -> SessionIdentityHarness {
        SessionIdentityHarness(storage: InMemoryLocalStorage(target), clock: clock, deviceId: "NEW")
    }

    func test_S42_theFirstLaunchAfterAnUpgradeKeepsTheOldDeviceId() async {
        legacy["digia_anonymous_id"] = "A0"
        migrate()

        let h = launch()
        XCTAssertEqual(h.identity.deviceId, "A0")
        await h.reporter.report()?.value
        XCTAssertEqual(h.network.attempts.first?.anonymousId, "A0")
        let headers = SDKRequestHeaders.make(config: DigiaConfig(apiKey: "key"), deviceId: h.identity.deviceId)
        XCTAssertEqual(headers["X-Digia-Device-Id"], "A0")
    }

    func test_S42b_theSecondOldLocationIsUsedWhenTheFirstIsMissing() {
        legacy["digia_engage_device_id"] = "E0"
        migrate()
        XCTAssertEqual(launch().identity.deviceId, "E0")
    }

    func test_S43a_theOldLocationsAreTriedInAFixedOrder() {
        legacy["digia_anonymous_id"] = "A0"
        legacy["digia_engage_device_id"] = "E0"
        migrate()
        XCTAssertEqual(launch().identity.deviceId, "A0")
    }

    func test_S43b_aValueAlreadyInTheNewLocationWins() {
        target["identity.device_id"] = "N0"
        legacy["digia_anonymous_id"] = "A0"
        migrate()
        XCTAssertEqual(launch().identity.deviceId, "N0")
    }

    func test_S44_theOldUserIdIsCarriedOverWithoutRotating() {
        legacy["digia_user_id"] = "asha"
        migrate()

        let h = launch()
        XCTAssertEqual(h.identity.userId, "asha")
        XCTAssertEqual(h.rotations.calls, 0)
        XCTAssertTrue(h.network.attempts.isEmpty)
    }

    func test_S45_aValueThatFailsToCopyIsSkippedAndNothingElseIsLost() {
        legacy["digia_anonymous_id"] = "A0"
        legacy["digia_user_id"] = "asha"
        legacy["digia_live_testing_enabled"] = "YES"   // UserDefaults reads this string as true
        targetStore.unwritableKeys = ["identity.device_id"]

        migrate()

        XCTAssertNil(target["identity.device_id"], "the failed copy is lost (one-shot, D10)")
        XCTAssertEqual(target["identity.user_id"] as? String, "asha")
        XCTAssertEqual(target["live_test.enabled"] as? Bool, true)
        XCTAssertEqual(target["storage.version"] as? Int, 1)
        XCTAssertNil(legacy["digia_anonymous_id"])
        XCTAssertNil(legacy["digia_user_id"])
        XCTAssertEqual(launch().identity.deviceId, "NEW")
    }

    func test_S45b_theMigrationRunsOnce() {
        legacy["digia_user_id"] = "asha"
        migrate()

        legacy["digia_anonymous_id"] = "LATE"
        legacy["digia_user_id"] = "ravi"
        let readsBefore = legacyStore.reads.count
        migrate()

        XCTAssertEqual(legacyStore.reads.count, readsBefore, "the marker says done, so nothing is read")
        XCTAssertEqual(target["identity.user_id"] as? String, "asha")
        XCTAssertNil(target["identity.device_id"])
    }

    func test_S46_theFirstLaunchAfterAnUpgradeStartsANewSession() {
        legacy["digia_anonymous_id"] = "A0"
        legacy["digia_user_id"] = "asha"
        migrate()

        XCTAssertTrue(target.keys.filter { $0.hasPrefix("session.") }.isEmpty, "no migrator copies session keys")
        let h = launch()
        XCTAssertFalse(h.session.resumedAtStartup)
    }
}
