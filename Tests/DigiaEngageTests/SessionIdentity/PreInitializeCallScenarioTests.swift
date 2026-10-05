import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.11: `setUserId` / `clearUserId` before `initialize`, and retries. Runs the real
/// `initialize` (`InitializeHarness`). S54's setup-failure case doesn't apply on iOS: a retry keeps
/// the services the first call built (#77).
@MainActor
final class PreInitializeCallScenarioTests: XCTestCase {

    private func savedAshaWithAStaleSession() -> InitializeHarness {
        let h = InitializeHarness(clock: TestClock(10, 0))
        h.seedUser("asha")
        h.seedSession("yesterday", lastActivityMs: TestClock.at(10, 0) - 24 * 3_600_000)
        h.launch()
        return h
    }

    func test_S51_theLastCallBeforeInitializeWinsWithOneRotation() async throws {
        let h = InitializeHarness(clock: TestClock(10, 0))
        h.sdk.setUserId("asha")
        h.sdk.clearUserId()
        h.sdk.setUserId("ravi")
        try await h.initialize()
        await h.settle()

        XCTAssertEqual(h.services.identityManager.userId, "ravi")
        XCTAssertEqual(h.network.attempts.map(\.userId), [nil, "ravi"], "the startup report, then one rotation")
        XCTAssertEqual(h.network.attempts.last?.sessionId, h.services.sessionManager.sessionId)
    }

    func test_S52_aBlankUserIdDoesNotCancelABufferedClear() async throws {
        let h = savedAshaWithAStaleSession()
        h.sdk.clearUserId()
        h.sdk.setUserId("")
        h.sdk.setUserId("   ")
        try await h.initialize()
        await h.settle()

        XCTAssertNil(h.services.identityManager.userId)
        XCTAssertEqual(h.network.attempts.map(\.userId), ["asha", nil])
    }

    func test_S53_aClearBeforeInitializeReportsTheSavedUserThenAnAnonymousSession() async throws {
        let h = savedAshaWithAStaleSession()
        h.sdk.clearUserId()
        try await h.initialize()
        await h.settle()

        let reports = h.network.attempts
        XCTAssertEqual(reports.map(\.userId), ["asha", nil])
        XCTAssertEqual(reports.last?.sessionId, h.services.sessionManager.sessionId)
        XCTAssertNotEqual(reports.first?.sessionId, reports.last?.sessionId)
    }

    func test_S54_aRetryAfterAFailedFetchAppliesTheBufferedCallOnce() async throws {
        let h = InitializeHarness(clock: TestClock(10, 0))
        h.sdk.setUserId("asha")
        try await h.initialize()
        XCTAssertEqual(h.sdk.sdkState, .failed, "precondition: the fake network has no campaign bundle")
        let services = h.services

        h.clock.set(10, 0, 5)
        try await h.initialize()
        await h.settle()

        XCTAssertTrue(h.services === services, "a retry keeps the services")
        XCTAssertEqual(h.services.identityManager.userId, "asha")
        XCTAssertEqual(h.network.attempts.map(\.userId), [nil, "asha"])
    }
}
