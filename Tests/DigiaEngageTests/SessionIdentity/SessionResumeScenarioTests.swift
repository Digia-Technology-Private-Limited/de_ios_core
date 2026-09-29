import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.2: resuming after a process kill. A relaunch is a second `SessionManager`
/// over the same storage.
final class SessionResumeScenarioTests: XCTestCase {

    private func relaunch(_ storage: InMemoryLocalStorage, at clock: TestClock) -> SessionManager {
        SessionManager(storage: storage.scoped("session"), clock: clock.closure, observeLifecycle: false)
    }

    // S6. Deferred part: "does not report it again" is the startup-report decision in SDKInstance.
    func test_S6_relaunchWithin30MinutesResumesAndRestartsTheWindow() {
        let storage = InMemoryLocalStorage()
        let clock = TestClock(9, 30)
        let first = relaunch(storage, at: clock)
        let s1 = first.sessionId
        clock.set(10, 0)
        first.onBackground()

        clock.set(10, 29)
        let second = relaunch(storage, at: clock)
        XCTAssertTrue(second.resumedAtStartup)
        XCTAssertEqual(second.sessionId, s1)
        XCTAssertEqual(storage.string(forKey: "session.last_activity_ms"), String(TestClock.at(10, 29)))

        clock.set(10, 58)
        second.touch()
        XCTAssertEqual(second.sessionId, s1, "29 minutes after the relaunch, 58 after 10:00")
    }

    // S7. Deferred part: "reports it once" is the startup-report decision in SDKInstance.
    func test_S7_relaunch30MinutesOrMoreLaterStartsANewSession() {
        let storage = InMemoryLocalStorage()
        let clock = TestClock(9, 30)
        let first = relaunch(storage, at: clock)
        let s1 = first.sessionId
        clock.set(10, 0)
        first.onBackground()

        clock.set(10, 31)
        let second = relaunch(storage, at: clock)
        XCTAssertFalse(second.resumedAtStartup)
        XCTAssertNotEqual(second.sessionId, s1)
        XCTAssertEqual(storage.string(forKey: "session.session_id"), second.sessionId)
    }

    func test_S8_aForegroundCrashMeasuresFromTheSavedTimeWhichLagsUpTo10Seconds() {
        let storage = InMemoryLocalStorage()
        let clock = TestClock(10, 0, 0)
        let first = relaunch(storage, at: clock)
        let s1 = first.sessionId

        clock.set(10, 0, 8)
        first.touch()                      // memory only
        XCTAssertEqual(storage.string(forKey: "session.last_activity_ms"), String(TestClock.at(10, 0, 0)))
        // crash at 10:00:09: no background step

        clock.set(10, 30, 5)
        let second = relaunch(storage, at: clock)
        XCTAssertFalse(second.resumedAtStartup, "30:05 since the saved 10:00:00")
        XCTAssertNotEqual(second.sessionId, s1)
    }

    func test_S8b_anEventTenSecondsAfterTheLastSaveReachesDisk() {
        let storage = InMemoryLocalStorage()
        let clock = TestClock(10, 0, 0)
        let first = relaunch(storage, at: clock)
        let s1 = first.sessionId

        clock.set(10, 0, 10)
        first.touch()
        XCTAssertEqual(storage.string(forKey: "session.last_activity_ms"), String(TestClock.at(10, 0, 10)))

        clock.set(10, 30, 5)
        let second = relaunch(storage, at: clock)
        XCTAssertTrue(second.resumedAtStartup)
        XCTAssertEqual(second.sessionId, s1)
    }
}
