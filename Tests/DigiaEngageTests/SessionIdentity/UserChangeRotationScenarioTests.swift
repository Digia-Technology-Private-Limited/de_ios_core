import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.4: rotation when the user changes, and rotation listeners. Built through
/// `SessionIdentityWiring.attach()`, as the composition root does.
final class UserChangeRotationScenarioTests: XCTestCase {

    func test_S12_settingAUserForTheFirstTimeRotatesAndReportsWithThatUser() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let s1 = h.session.sessionId

        h.clock.set(10, 5)
        h.identity.setUserId("asha")
        await h.settle()

        let s2 = h.session.sessionId
        XCTAssertNotEqual(s2, s1)
        XCTAssertEqual(h.network.attempts.map(\.sessionId), [s2])
        XCTAssertEqual(h.network.attempts.first?.userId, "asha")
    }

    func test_S13_settingTheSameUserAgainDoesNothingEvenWithSurroundingWhitespace() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        h.identity.setUserId("asha")
        await h.settle()
        let s2 = h.session.sessionId
        let reportsBefore = h.network.attempts.count

        h.identity.setUserId("asha")
        h.identity.setUserId("asha")
        h.identity.setUserId(" asha ")
        await h.settle()

        XCTAssertEqual(h.session.sessionId, s2)
        XCTAssertEqual(h.rotations.calls, 1)
        XCTAssertEqual(h.network.attempts.count, reportsBefore)
    }

    func test_S14_switchingDirectlyToAnotherUserRotatesOnce() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        h.identity.setUserId("asha")
        await h.settle()

        h.clock.set(10, 20)
        h.identity.setUserId("ravi")
        await h.settle()

        let s3 = h.session.sessionId
        XCTAssertEqual(h.rotations.calls, 2)
        let forS3 = h.network.attempts.filter { $0.sessionId == s3 }
        XCTAssertEqual(forS3.map(\.userId), ["ravi"], "no report says asha for S3")
    }

    func test_S15_loggingOutRotatesOnceAndClearingWithNoUserDoesNothing() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        h.identity.setUserId("asha")
        await h.settle()

        h.clock.set(10, 30)
        h.identity.clearUserId()
        await h.settle()
        let s4 = h.session.sessionId
        XCTAssertEqual(h.network.attempts.last?.sessionId, s4)
        XCTAssertNil(h.network.attempts.last?.userId)

        h.clock.set(10, 31)
        h.identity.clearUserId()
        await h.settle()
        XCTAssertEqual(h.session.sessionId, s4)
        XCTAssertEqual(h.rotations.calls, 2)
        XCTAssertEqual(h.network.attempts.count, 2)
    }

    func test_S15b_clearingWhenNobodyWasEverLoggedInDoesNothing() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let s1 = h.session.sessionId
        h.identity.clearUserId()
        await h.settle()
        XCTAssertEqual(h.session.sessionId, s1)
        XCTAssertTrue(h.network.attempts.isEmpty)
    }

    // S16 as coded, pending decision: scenarios doc §6 item 5 (sessions with no events).
    func test_S16_asCoded_logoutThenLoginAsTheSameUserCreatesTwoNewSessions() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        h.identity.setUserId("asha")
        await h.settle()
        let before = h.network.attempts.count

        h.clock.set(11, 0)
        h.identity.clearUserId()
        h.identity.setUserId("asha")
        await h.settle()

        let refresh = Array(h.network.attempts.dropFirst(before))
        XCTAssertEqual(refresh.count, 2)
        XCTAssertEqual(refresh.map(\.userId), [nil, "asha"])
        XCTAssertEqual(Set(refresh.map(\.sessionId)).count, 2)
        XCTAssertEqual(refresh.last?.sessionId, h.session.sessionId)
    }

    func test_S17_aBlankUserIdIsIgnored() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        h.identity.setUserId("asha")
        await h.settle()
        let s2 = h.session.sessionId

        h.identity.setUserId("")
        h.identity.setUserId("   ")
        await h.settle()

        XCTAssertEqual(h.identity.userId, "asha")
        XCTAssertEqual(h.session.sessionId, s2)
        XCTAssertEqual(h.rotations.calls, 1)
    }

    func test_S18_aForcedRotationCallsEachListenerOnceAfterTheNewIdIsInPlace() async {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        let storage = h.storage
        var savedInsideListener: String?
        h.session.addRotationListener { savedInsideListener = storage.string(forKey: "session.session_id") }
        let s6 = h.session.sessionId

        h.clock.set(10, 40)
        h.session.reset()
        await h.settle()

        let s7 = h.session.sessionId
        XCTAssertNotEqual(s7, s6)
        XCTAssertEqual(h.rotations.seenSessionIds, [s7])
        XCTAssertEqual(savedInsideListener, s7, "saved before the listeners run")
        XCTAssertEqual(h.network.attemptedSessions, [s7], "the reporter reads S7, and S6 isn't reported again")
    }

    // S19 as coded, pending decision: scenarios doc §6 item 8 (failing or duplicated listener).
    // iOS listeners are non-throwing closures, so the failing-listener half can't happen on iOS.
    // A listener registered twice is kept twice and runs twice.
    func test_S19_asCoded_aListenerRegisteredTwiceIsCalledTwice() {
        let h = SessionIdentityHarness(clock: TestClock(10, 0), attach: false)
        var calls = 0
        let listener = { calls += 1 }
        h.session.addRotationListener(listener)
        h.session.addRotationListener(listener)

        h.session.reset()

        XCTAssertEqual(calls, 2)
    }
}
