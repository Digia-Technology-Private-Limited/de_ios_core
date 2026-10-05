import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.6: offline durability and no duplicate reports.
final class ReportDurabilityScenarioTests: XCTestCase {

    private let storage = InMemoryLocalStorage()
    private let network = FakeNetworkClient()
    private let session = SessionIdBox("S1")
    private lazy var reporter = makeReporter(storage: storage, network: network, session: session)

    private func report(_ sid: String) async {
        session.value = sid
        await reporter.report()?.value
    }

    private func seedPending(_ sids: [String]) async {
        network.answerAll(.noResponse)
        for sid in sids { await report(sid) }
        XCTAssertEqual(pendingSessionIds(storage), sids)
        network.answerAll(.status(200))
    }

    func test_S24_anUnsentReportIsKeptAndSentLaterOldestFirst() async {
        network.answerAll(.noResponse)
        await report("S1")                       // 10:00 on the flight
        await report("S2")                       // 11:00
        XCTAssertEqual(pendingSessionIds(storage), ["S1", "S2"])

        network.answerAll(.status(200))
        let before = network.attempts.count
        await report("S3")                       // 13:00, landed

        XCTAssertEqual(Array(network.attemptedSessions.dropFirst(before)), ["S1", "S2", "S3"])
        XCTAssertEqual(pendingSessionIds(storage), [])
    }

    func test_S25_onlyRetryableFailuresAreKept() async {
        let cases: [(FakeNetworkClient.Answer, Bool)] = [
            (.status(503), true), (.status(500), true), (.status(408), true), (.status(429), true),
            (.noResponse, true), (.status(400), false), (.status(401), false), (.status(404), false),
        ]
        for (answer, kept) in cases {
            let storage = InMemoryLocalStorage()
            let reporter = makeReporter(storage: storage, network: network, session: SessionIdBox("S1"))
            network.answerAll(answer)
            await reporter.report()?.value
            withExtendedLifetime(reporter) {}   // the reporter's task holds it weakly
            XCTAssertEqual(pendingSessionIds(storage), kept ? ["S1"] : [], "\(answer)")
        }
    }

    func test_S25b_a503IsKeptThenA400BehindItIsDropped() async {
        network.answer { $0.sessionId == "S1" ? .status(503) : .status(400) }
        await report("S1")
        XCTAssertEqual(pendingSessionIds(storage), ["S1"])

        network.answer { _ in .status(400) }
        await report("S2")
        XCTAssertEqual(pendingSessionIds(storage), [], "400s are dropped, not retried")
    }

    func test_S26_resendingStopsAtTheFirstFailureAndKeepsTheRestInOrder() async {
        await seedPending(["S1", "S2", "S3"])

        network.answer { $0.sessionId == "S1" ? .status(200) : .status(500) }
        let before = network.attempts.count
        await reporter.flush().value
        XCTAssertEqual(Array(network.attemptedSessions.dropFirst(before)), ["S1", "S2"])
        XCTAssertEqual(pendingSessionIds(storage), ["S2", "S3"])

        await report("S4")
        XCTAssertEqual(pendingSessionIds(storage), ["S2", "S3", "S4"])
    }

    func test_S27_thePendingListKeepsThe20NewestReports() async {
        network.answerAll(.noResponse)
        for i in 1...25 { await report("S\(i)") }
        XCTAssertEqual(pendingSessionIds(storage), (6...25).map { "S\($0)" })
    }

    func test_S23_aReportCarriesTheSessionAndUserAsTheyWereWhenItWasMade() async {
        let h = SessionIdentityHarness(storage: storage, clock: TestClock(10, 0), network: network)
        network.answerAll(.noResponse)
        h.session.reset()                       // S1, kept
        await h.settle()
        let s1 = h.session.sessionId
        let before = network.attempts.count

        network.answerAll(.status(200))
        let started = expectation(description: "re-send of S1 started")
        network.holdNext { started.fulfill() }
        h.reporter.flush()                      // the slow re-send of S1
        await fulfillment(of: [started], timeout: 5)

        h.clock.set(10, 5)
        h.identity.setUserId("asha")            // S2's report is made now, then waits behind it
        let s2 = h.session.sessionId

        h.clock.set(10, 6)
        h.identity.clearUserId()                // rotates to S3 while S2 waits
        let s3 = h.session.sessionId
        network.release()
        await h.settle()

        let sent = Array(network.attempts.dropFirst(before))
        XCTAssertEqual(sent.map(\.sessionId), [s1, s2, s3])
        XCTAssertEqual(sent.map(\.userId), [nil, "asha", nil])
    }

    // S28. Deferred part: that a resumed launch calls flush() is the startup decision in SDKInstance.
    // Tested here: a flush sends the pending report and reports no new session.
    func test_S28_aFlushOnAResumedLaunchSendsPendingReportsWithoutANewOne() async {
        await seedPending(["S1"])
        let before = network.attempts.count

        session.value = "S1"                    // resumed
        await reporter.flush().value

        XCTAssertEqual(Array(network.attemptedSessions.dropFirst(before)), ["S1"])
        XCTAssertEqual(pendingSessionIds(storage), [])
    }

    // S29 as coded, pending decision: scenarios doc §6 item 7 (no network-recovery trigger).
    func test_S29_asCoded_pendingReportsAreNotResentWhenTheNetworkReturnsMidSession() async {
        let h = SessionIdentityHarness(storage: storage, clock: TestClock(10, 0), network: network)
        network.answerAll(.noResponse)
        h.session.reset()                       // S1 report at 10:00, kept
        await h.settle()
        XCTAssertEqual(pendingSessionIds(storage).count, 1)

        network.answerAll(.status(200))         // 10:02, network back
        let before = network.attempts.count
        for minute in stride(from: Int64(5), through: 120, by: 5) {
            h.clock.setRaw(TestClock.at(10, 0) + minute * 60_000)
            h.session.touch()
        }

        XCTAssertEqual(network.attempts.count, before, "nothing re-sent for two hours")
        XCTAssertEqual(pendingSessionIds(storage).count, 1)
    }

    // S30 (known bug SI-B3, plan §5.2): asserts the INTENDED behavior, a report is on the pending
    // list before it is sent and removed after success. Expected to fail on iOS today.
    func test_S30_aReportIsSavedBeforeItIsSentAndRemovedAfterSuccess() async {
        let started = expectation(description: "send started")
        network.holdNext { started.fulfill() }
        session.value = "S1"
        let task = reporter.report()

        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(pendingSessionIds(storage), ["S1"], "on disk while in flight, so a process death can't lose it")

        network.release()
        await task?.value
        XCTAssertEqual(pendingSessionIds(storage), [])
    }

    func test_S32_aReportThatSucceededIsNeverSentAgain() async {
        await report("S1")                       // 200
        network.answer { $0.sessionId == "S2" ? .status(500) : .status(200) }
        await report("S2")                       // kept
        network.answerAll(.status(200))
        await report("S3")                       // re-sends S2, then S3
        await reporter.flush().value

        XCTAssertEqual(network.attemptedSessions.filter { $0 == "S1" }.count, 1)
        XCTAssertEqual(network.attemptedSessions, ["S1", "S2", "S2", "S3"])
    }

    func test_S33_twoQuickRotationsProduceTwoReportsInOrder() async {
        let h = SessionIdentityHarness(storage: storage, clock: TestClock(10, 0), network: network)
        h.identity.setUserId("asha")
        await h.settle()
        network.answerAll(.noResponse)          // offline
        let before = pendingSessionIds(storage)

        h.identity.clearUserId()
        let s3 = h.session.sessionId
        h.identity.setUserId("asha")
        let s4 = h.session.sessionId
        await h.settle()

        XCTAssertNotEqual(s3, s4)
        XCTAssertEqual(pendingSessionIds(storage), before + [s3, s4])
    }
}
