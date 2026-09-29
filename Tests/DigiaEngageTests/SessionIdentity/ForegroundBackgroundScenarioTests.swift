import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.3: foreground and background. The foreground step is `touch()` and the
/// background step is `onBackground()`, the two calls the lifecycle observers make.
final class ForegroundBackgroundScenarioTests: XCTestCase {

    func test_S9_goingToTheBackgroundSavesTheActivityTimeAtOnce() {
        let storage = InMemoryLocalStorage()
        let clock = TestClock(10, 0, 0)
        let first = SessionManager(storage: storage.scoped("session"), clock: clock.closure, observeLifecycle: false)
        let s1 = first.sessionId

        clock.set(10, 0, 3)
        first.touch()
        XCTAssertEqual(storage.string(forKey: "session.last_activity_ms"), String(TestClock.at(10, 0, 0)))

        clock.set(10, 7)
        first.onBackground()
        XCTAssertEqual(storage.string(forKey: "session.last_activity_ms"), String(TestClock.at(10, 7)))

        clock.set(10, 36)
        let second = SessionManager(storage: storage.scoped("session"), clock: clock.closure, observeLifecycle: false)
        XCTAssertTrue(second.resumedAtStartup)
        XCTAssertEqual(second.sessionId, s1)
    }

    func test_S10_comingBackAfter30MinutesInBackgroundStartsNewSession() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let ref = CurrentSessionRef()
        ref.set(h.session, requestHeaders: [:])
        let s1 = h.session.sessionId

        h.session.onBackground()
        h.clock.set(10, 45)
        h.session.touch()                  // the foreground step
        await h.settle()

        let s2 = h.session.sessionId
        XCTAssertNotEqual(s2, s1, "rotated at the moment of return, without an event")
        XCTAssertEqual(h.rotations.calls, 1)
        XCTAssertEqual(h.network.attemptedSessions, [s2])
        XCTAssertEqual(ref.sessionId, s2, "the next request's session header")
    }

    func test_S11_briefInterruptionsAndReturnsWithin30MinutesKeepTheSession() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let s1 = h.session.sessionId

        // 10:10 notification shade and 10:12 phone call: on iOS these don't enter the background,
        // so there is no lifecycle step. 10:20 to 10:35: another app.
        h.clock.set(10, 20)
        h.session.onBackground()
        h.clock.set(10, 35)
        h.session.touch()                  // the foreground step
        await h.settle()

        XCTAssertEqual(h.session.sessionId, s1)
        XCTAssertEqual(h.rotations.calls, 0)
        XCTAssertTrue(h.network.attempts.isEmpty)
    }
}
