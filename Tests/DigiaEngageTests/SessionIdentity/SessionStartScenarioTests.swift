import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.1: session start and the 30-minute inactivity rule.
final class SessionStartScenarioTests: XCTestCase {

    // S1. Deferred part: "reported once" depends on the startup-report decision in SDKInstance (plan §5.1).
    func test_S1_freshInstallStartsExactlyOneSession() {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))

        XCTAssertFalse(h.session.resumedAtStartup)
        XCTAssertFalse(h.session.sessionId.isEmpty)
        XCTAssertEqual(h.storage.string(forKey: "session.session_id"), h.session.sessionId)
        XCTAssertEqual(h.storage.string(forKey: "session.last_activity_ms"), String(TestClock.at(10, 0)))
        XCTAssertEqual(h.rotations.calls, 0, "starting S1 is not a rotation")
    }

    func test_S2_activityLessThan30MinutesApartKeepsTheSameSession() {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let s1 = h.session.sessionId

        for (hour, minute) in [(10, 10), (10, 35), (11, 0), (11, 25)] as [(Int64, Int64)] {
            h.clock.set(hour, minute)
            h.session.touch()
            XCTAssertEqual(h.session.sessionId, s1, "event at \(hour):\(minute)")
        }
        XCTAssertEqual(h.rotations.calls, 0)
    }

    func test_S3a_anEventAt10_29_59_999StillCarriesTheOldSession() {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let s1 = h.session.sessionId

        h.clock.set(10, 29, 59, 999)
        h.session.touch()
        XCTAssertEqual(h.session.sessionId, s1)
        XCTAssertEqual(h.rotations.calls, 0)
    }

    func test_S3b_exactly30MinutesExpiresAndTheTriggeringEventCarriesTheNewSession() {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let s1 = h.session.sessionId

        h.clock.set(10, 30, 0, 0)
        h.session.touch()
        let s2 = h.session.sessionId
        XCTAssertNotEqual(s2, s1)
        XCTAssertEqual(h.rotations.seenSessionIds, [s2], "rotated before the event read its session")
    }

    func test_S4_anExpiredSessionRotatesOnceForABurstOfEvents() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let s1 = h.session.sessionId

        h.clock.set(10, 45)
        var seen: [String] = []
        for _ in 0..<3 {
            h.session.touch()
            seen.append(h.session.sessionId)
        }
        await h.settle()

        XCTAssertEqual(Set(seen).count, 1)
        XCTAssertNotEqual(seen[0], s1)
        XCTAssertEqual(h.rotations.calls, 1)
        XCTAssertEqual(h.network.attemptedSessions, [seen[0]], "S2 is reported once")
    }

    // S5 (known bug SI-B2, plan §5.2): asserts the INTENDED rule, coming back to the foreground
    // counts as activity (session-unification.md §2.1). Expected to fail on iOS today.
    // Left out: the cold-start example (09:00 open, 09:45 first event), because a 45-minute gap
    // still expires even under the intended rule; see the report.
    func test_S5_comingBackToTheForegroundCountsAsActivity() {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let s1 = h.session.sessionId

        h.session.onBackground()           // 10:00, saved
        h.clock.set(10, 20)
        h.session.maybeExpire()            // the foreground step
        XCTAssertEqual(h.session.sessionId, s1)

        h.clock.set(10, 31)
        h.session.touch()                  // campaign impression
        XCTAssertEqual(h.session.sessionId, s1, "Asha was never away for more than 20 minutes")
    }
}
