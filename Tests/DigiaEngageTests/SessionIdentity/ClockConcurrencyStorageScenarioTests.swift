import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.12: clock changes, concurrent calls and corrupt storage.
/// Not pure, so left out: S61's type conversion inside the UserDefaults adapter (plan §5.1). S61 is
/// tested at the IdentityManager level with the value UserDefaults would hand back.
final class ClockConcurrencyStorageScenarioTests: XCTestCase {

    func test_S55_aTimeZoneChangeHasNoEffectOnSessions() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        NSTimeZone.default = TimeZone(identifier: "Asia/Kolkata")!
        // The production clock, which is what a time-zone change could affect.
        let manager = SessionManager(storage: InMemoryLocalStorage(), observeLifecycle: false)
        let s1 = manager.sessionId
        let before = manager.lastActivityMs

        NSTimeZone.default = TimeZone(identifier: "Asia/Dubai")!
        manager.touch()

        XCTAssertEqual(manager.sessionId, s1)
        XCTAssertLessThan(abs(manager.lastActivityMs - before), 60_000, "epoch milliseconds, not local time")
    }

    func test_S56_aClockMovedForwardLooksLikeInactivity() {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let s1 = h.session.sessionId
        h.clock.set(10, 10)
        h.session.touch()

        h.clock.set(12, 10)                     // jumped two hours
        h.session.touch()
        XCTAssertNotEqual(h.session.sessionId, s1)
    }

    // S57 as coded, pending decision: scenarios doc §6 item 4 (clock moved backward).
    func test_S57_asCoded_aClockMovedBackwardNeverEndsTheSession() {
        let storage = InMemoryLocalStorage()
        let dayMs: Int64 = 86_400_000
        let clock = TestClock()
        clock.setRaw(TestClock.at(10, 0) + dayMs)       // "Tuesday 10:00", really Monday 10:00
        let first = SessionManager(storage: storage.scoped("session"), clock: clock.closure, observeLifecycle: false)
        let s1 = first.sessionId
        first.onBackground()

        clock.set(18, 0)                                 // Monday 18:00, corrected
        let second = SessionManager(storage: storage.scoped("session"), clock: clock.closure, observeLifecycle: false)
        XCTAssertTrue(second.resumedAtStartup, "a gap of minus 16 hours counts as less than 30 minutes")
        XCTAssertEqual(second.sessionId, s1)

        // In process, a backward jump never rotates either.
        clock.set(9, 0)
        second.touch()
        clock.set(9, 1)
        second.touch()
        XCTAssertEqual(second.sessionId, s1)
    }

    func test_S58_simultaneousEventsOnDifferentThreadsJustAfterExpiryRotateOnce() async {
        for _ in 0..<50 {
            let h = SessionIdentityHarness(clock: TestClock(10, 0))
            h.clock.set(10, 40)
            h.clock.readPauseMicros = 200
            let session = h.session
            DispatchQueue.concurrentPerform(iterations: 8) { _ in session.touch() }
            await h.settle()

            XCTAssertEqual(h.rotations.calls, 1)
            XCTAssertEqual(h.network.attempts.count, 1)
        }
    }

    func test_S59_racingSetUserIdCallsRotateTwiceAndTheLastSetWins() {
        for _ in 0..<50 {
            let h = SessionIdentityHarness(clock: TestClock(10, 0))
            let identity = h.identity
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                identity.setUserId(i == 0 ? "asha" : "ravi")
            }

            XCTAssertEqual(h.rotations.calls, 2)
            let finalUser = h.identity.userId
            XCTAssertTrue(finalUser == "asha" || finalUser == "ravi")
            XCTAssertEqual(h.storage.string(forKey: "identity.user_id"), finalUser, "memory and disk agree")
        }
    }

    func test_S60a_aCorruptSavedActivityStartsANewSession() {
        let storage = InMemoryLocalStorage()
        storage.set("S0", forKey: "session.session_id")
        storage.set("abc", forKey: "session.last_activity_ms")
        let h = SessionIdentityHarness(storage: storage)
        XCTAssertFalse(h.session.resumedAtStartup)
        XCTAssertNotEqual(h.session.sessionId, "S0")
    }

    func test_S60b_aMissingSavedActivityWithASessionIdStartsANewSession() {
        let storage = InMemoryLocalStorage()
        storage.set("S0", forKey: "session.session_id")
        let h = SessionIdentityHarness(storage: storage)
        XCTAssertFalse(h.session.resumedAtStartup)
        XCTAssertNotEqual(h.session.sessionId, "S0")
    }

    func test_S60c_aBlankSavedSessionIdStartsANewSession() {
        let storage = InMemoryLocalStorage()
        storage.set("   ", forKey: "session.session_id")
        storage.set(String(TestClock.at(9, 55)), forKey: "session.last_activity_ms")
        let h = SessionIdentityHarness(storage: storage, clock: TestClock(10, 0))
        XCTAssertFalse(h.session.resumedAtStartup)
        XCTAssertNotEqual(h.session.sessionId, "   ")
    }

    func test_S61a_aBlankSavedDeviceIdIsReplaced() {
        let storage = InMemoryLocalStorage()
        storage.set("   ", forKey: "identity.device_id")
        let h = SessionIdentityHarness(storage: storage, deviceId: "D1")
        XCTAssertEqual(h.identity.deviceId, "D1")
        XCTAssertEqual(storage.string(forKey: "identity.device_id"), "D1")
    }

    func test_S62a_aPendingListThatIsNotJsonReadsAsEmptyAndIsOverwritten() async {
        let storage = InMemoryLocalStorage()
        let network = FakeNetworkClient()
        storage.set("{not json", forKey: "session.\(SessionReporter.keyPendingReport)")
        network.answerAll(.noResponse)

        let reporter = makeReporter(storage: storage, network: network, session: SessionIdBox("S5"))
        await reporter.report()?.value
        withExtendedLifetime(reporter) {}   // the reporter's task holds it weakly

        XCTAssertEqual(network.attemptedSessions, ["S5"])
        XCTAssertEqual(pendingSessionIds(storage), ["S5"])
    }

    func test_S62b_oneBadPendingEntryIsSkippedAndTheRestAreSent() async {
        let storage = InMemoryLocalStorage()
        let network = FakeNetworkClient()
        let good = String(data: try! JSONSerialization.data(withJSONObject: ["session_id": "S1", "anonymous_id": "D1"]), encoding: .utf8)!
        let list = String(data: try! JSONSerialization.data(withJSONObject: [good, 5] as [Any]), encoding: .utf8)!
        storage.set(list, forKey: "session.\(SessionReporter.keyPendingReport)")

        let reporter = makeReporter(storage: storage, network: network, session: SessionIdBox("S2"))
        await reporter.report()?.value
        withExtendedLifetime(reporter) {}   // the reporter's task holds it weakly

        XCTAssertEqual(network.attemptedSessions, ["S1", "S2"])
    }

    func test_S63_aDeviceIdThatCanNotBeSavedIsUsedOnceAndReplacedNextLaunch() {
        let storage = InMemoryLocalStorage()
        storage.dropWrites = true
        let first = IdentityManager(storage: storage.scoped("identity"), idGenerator: { "D1" })
        XCTAssertEqual(first.deviceId, "D1")

        storage.dropWrites = false
        let next = IdentityManager(storage: storage.scoped("identity"), idGenerator: { "D2" })
        XCTAssertEqual(next.deviceId, "D2")
    }
}
