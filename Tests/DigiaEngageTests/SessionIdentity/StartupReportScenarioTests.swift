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

}
