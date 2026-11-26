import Testing
@testable import DigiaEngage

struct GameFunnelStatsTests {
    final class Clock: @unchecked Sendable { var now: Int64 = 0 }

    private func answer(_ response: [String: Any]) -> [String: Any] {
        ["isSuccess": true, "data": ["response": response]]
    }

    @Test func dwellCountsOnlyForegroundTimeAfterTheGameShowed() {
        let clock = Clock()
        let stats = GameFunnelStats(chanceId: "open-chance") { clock.now }
        clock.now = 100
        stats.setForeground(false) // backgrounded while loading: nothing counted yet
        stats.start()
        clock.now = 500
        stats.setForeground(true)
        clock.now = 1_500
        stats.setForeground(false)
        clock.now = 9_000 // backgrounded stretch is excluded
        stats.setForeground(true)
        clock.now = 9_250

        #expect(stats.dwellMs() == 1_250)
    }

    @Test func playsCountOutcomesAndRefusalFollowsTheLatestPlayOrPeek() {
        let stats = GameFunnelStats(chanceId: "open-chance") { 0 }
        stats.recordHttp(path: "play", response: answer(["outcomeKey": "win"]))
        stats.recordHttp(path: "peek", response: answer(["outcomeKey": "win", "refused": "exhausted"]))
        stats.recordHttp(path: "play", response: answer(["refused": "cooldown"]))
        stats.recordHttp(path: "claim", response: answer(["outcomeKey": "x"]))
        stats.recordHttp(path: "play", response: answer(["outcomeKey": "lose"]))

        #expect(stats.plays == 2)
        #expect(stats.playRefused == "cooldown")
    }

    // Guards the `latestChanceId` update in `recordHttp`: a replay plays a new
    // chance, so the window's events must name the latest one, not the open.
    @Test func chanceIdFollowsTheLatestPlayOrPeekAnswer() {
        let stats = GameFunnelStats(chanceId: "open-chance") { 0 }
        stats.recordHttp(path: "play", response: answer(["outcomeKey": "win", "chanceId": "ch-2"]))
        #expect(stats.chanceId == "ch-2")
        stats.recordHttp(path: "claim", response: answer(["chanceId": "ch-x"]))
        stats.recordHttp(path: "peek", response: answer(["chanceId": ""]))
        #expect(stats.chanceId == "ch-2")
        stats.recordHttp(path: "peek", response: answer(["chanceId": "ch-3"]))
        #expect(stats.chanceId == "ch-3")
        // The play answer carries no chanceId: the skin's request body names it.
        stats.recordHttp(path: "play", request: ["chanceId": "ch-4"], response: answer(["outcomeKey": "win"]))
        #expect(stats.chanceId == "ch-4")
    }

    // Guards the `state` branch in `recordHttp`: a fresh grant can lose to an older
    // unplayed chance, and Viewed must name the chance `state` answered with, not the
    // one the request asked about.
    @Test func stateAnswerNamesTheChanceButItsRequestNeverDoes() {
        let stats = GameFunnelStats(chanceId: "granted") { 0 }
        stats.recordHttp(path: "state", request: ["chanceId": "granted"], response: answer(["state": "playable", "chanceId": "older"]))
        #expect(stats.chanceId == "older")
        stats.recordHttp(path: "state", request: ["chanceId": "other"], response: answer(["state": "exhausted"]))
        #expect(stats.chanceId == "older")
    }
}
