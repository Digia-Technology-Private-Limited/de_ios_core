import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.8: user ID across restarts. A relaunch is a new graph over the same storage.
final class UserIdRestartScenarioTests: XCTestCase {

    // The startup report is covered by StartupReportScenarioTests.test_S39_theStartupReportCarriesTheSavedUser.
    // Tested: the user loads, loading doesn't rotate, and a report built now carries "asha".
    func test_S39_aSetUserIdSurvivesARestartWithoutRotating() async {
        let first = SessionIdentityHarness(clock: TestClock(10, 0))
        first.identity.setUserId("asha")
        await first.settle()

        let clock = TestClock(10, 10)
        let next = SessionIdentityHarness(storage: first.storage, clock: clock)
        XCTAssertEqual(next.identity.userId, "asha")
        XCTAssertTrue(next.session.resumedAtStartup)
        XCTAssertEqual(next.session.sessionId, first.session.sessionId)
        XCTAssertEqual(next.rotations.calls, 0)

        await next.reporter.report()?.value
        XCTAssertEqual(next.network.attempts.last?.userId, "asha")
    }

    func test_S40_aClearedUserStaysClearedAfterARestart() {
        let first = SessionIdentityHarness()
        first.identity.setUserId("asha")
        first.identity.clearUserId()

        let next = SessionIdentityHarness(storage: first.storage)
        XCTAssertNil(next.identity.userId)
    }

    func test_S41_aFailedSaveStillAppliesInMemoryAndDoesNotThrow() {
        let storage = InMemoryLocalStorage()
        let first = SessionIdentityHarness(storage: storage)
        first.identity.setUserId("old")
        storage.dropWrites = true               // disk full

        first.identity.setUserId("asha")
        XCTAssertEqual(first.identity.userId, "asha", "this launch uses asha")

        storage.dropWrites = false
        let next = SessionIdentityHarness(storage: storage)
        XCTAssertEqual(next.identity.userId, "old", "the next launch has the old value")
    }
}
