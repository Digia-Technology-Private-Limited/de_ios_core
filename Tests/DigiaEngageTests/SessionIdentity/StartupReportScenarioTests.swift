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
        XCTAssertEqual(h.network.attempts.first?.occurredAt, "2027-01-15T10:00:00.000Z", "the stored body, not a rebuilt one")
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

    func test_S20_ashasDayReportsEachNewSessionOnceAndNothingElse() async throws {
        let h = InitializeHarness(clock: TestClock(9, 0))
        try await h.initialize()                        // 09:00 open: new session
        await h.settle()
        let morning = h.services.sessionManager.sessionId

        h.clock.set(9, 10)                              // 09:10 relaunch: resumed
        h.launch()
        try await h.initialize()
        await h.settle()
        XCTAssertEqual(h.services.sessionManager.sessionId, morning)

        h.clock.set(9, 40)                              // backgrounded for 50 minutes
        h.services.sessionManager.onBackground()
        h.clock.set(10, 30)                             // 10:30 back: new session
        h.services.sessionManager.touch()
        await h.settle()
        let afternoon = h.services.sessionManager.sessionId

        h.clock.set(10, 35)                             // 10:35 log in: new session
        h.sdk.setUserId("asha")
        await h.settle()
        let loggedIn = h.services.sessionManager.sessionId

        h.clock.set(10, 40)                             // 10:40 relaunch: resumed
        h.launch()
        try await h.initialize()
        await h.settle()
        XCTAssertEqual(h.services.sessionManager.sessionId, loggedIn)

        XCTAssertEqual(h.network.attemptedSessions, [morning, afternoon, loggedIn])
        XCTAssertEqual(h.network.attempts.map(\.userId), [nil, nil, "asha"])
    }
}
