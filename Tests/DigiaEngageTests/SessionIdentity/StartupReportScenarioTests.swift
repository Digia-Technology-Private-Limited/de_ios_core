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

}
