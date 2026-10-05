import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.1, §3.5, §3.6 and §3.8: which sessions the real `initialize` reports, and
/// with which user. Runs `SDKInstance` over isolated defaults (`InitializeHarness`).
@MainActor
final class StartupReportScenarioTests: XCTestCase {

    func test_S1_aFreshInstallReportsTheStartupSessionOnce() async throws {
        let h = InitializeHarness(clock: TestClock(10, 0))
        try await h.initialize()
        await h.settle()

        let s1 = h.services.sessionManager.sessionId
        XCTAssertFalse(h.services.sessionManager.resumedAtStartup)
        XCTAssertEqual(h.network.attemptedSessions, [s1])
    }

    func test_S21_aUserSetBeforeInitializeIsReportedAfterTheAnonymousStartupSession() async throws {
        let h = InitializeHarness(clock: TestClock(10, 0))
        h.sdk.setUserId("asha")
        try await h.initialize()
        await h.settle()

        let s2 = h.services.sessionManager.sessionId
        let reports = h.network.attempts
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.map(\.userId), [nil, "asha"])
        XCTAssertNotEqual(reports.first?.sessionId, s2)
        XCTAssertEqual(reports.last?.sessionId, s2)
    }

    func test_S22_theSavedUserSetAgainBeforeInitializeIsReportedOnceWithThatUser() async throws {
        let h = InitializeHarness(clock: TestClock(10, 0))
        h.seedUser("asha")
        h.seedSession("yesterday", lastActivityMs: TestClock.at(10, 0) - 24 * 3_600_000)
        h.launch()
        h.sdk.setUserId("asha")
        try await h.initialize()
        await h.settle()

        let s1 = h.services.sessionManager.sessionId
        XCTAssertNotEqual(s1, "yesterday")
        XCTAssertEqual(h.network.attemptedSessions, [s1])
        XCTAssertEqual(h.network.attempts.first?.userId, "asha")
    }

    func test_S28_aResumedLaunchSendsThePendingReportAndNoNewOne() async throws {
        let h = InitializeHarness(clock: TestClock(10, 10))
        h.seedDevice("D1")
        h.seedSession("S1", lastActivityMs: TestClock.at(10, 5))
        h.seedPending([["session_id": "S1", "anonymous_id": "D1", "occurred_at": "2027-01-15T10:00:00.000Z"]])
        h.launch()
        try await h.initialize()
        try await h.waitForAttempts(1)          // not settle(): its own flush would send it too

        XCTAssertEqual(h.services.sessionManager.sessionId, "S1")
        XCTAssertEqual(h.network.attemptedSessions, ["S1"], "the pending report, and nothing new")
        XCTAssertEqual(h.network.attempts.first?.anonymousId, "D1")
        await h.settle()
        XCTAssertEqual(h.network.attemptedSessions, ["S1"], "sent once, then gone from the pending list")
    }

    func test_S39_theStartupReportCarriesTheSavedUser() async throws {
        let h = InitializeHarness(clock: TestClock(10, 0))
        h.seedUser("asha")
        h.seedSession("yesterday", lastActivityMs: TestClock.at(10, 0) - 24 * 3_600_000)
        h.launch()
        try await h.initialize()
        await h.settle()

        XCTAssertEqual(h.network.attempts.count, 1)
        XCTAssertEqual(h.network.attempts.first?.userId, "asha")
        XCTAssertEqual(h.services.identityManager.userId, "asha")
    }

}
