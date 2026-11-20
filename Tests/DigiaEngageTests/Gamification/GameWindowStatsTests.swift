import Testing
@testable import DigiaEngage

struct GameWindowStatsTests {
    final class Clock: @unchecked Sendable { var now: Int64 = 0 }

    private func answer(_ response: [String: Any]) -> [String: Any] {
        ["isSuccess": true, "data": ["response": response]]
    }

    @Test func dwellCountsOnlyForegroundTimeAfterTheGameShowed() {
        let clock = Clock()
        let stats = GameWindowStats(chanceId: "open-chance") { clock.now }
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
        let stats = GameWindowStats(chanceId: "open-chance") { 0 }
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
        let stats = GameWindowStats(chanceId: "open-chance") { 0 }
        stats.recordHttp(path: "play", response: answer(["outcomeKey": "win", "chanceId": "ch-2"]))
        #expect(stats.chanceId == "ch-2")
        stats.recordHttp(path: "claim", response: answer(["chanceId": "ch-x"]))
        stats.recordHttp(path: "peek", response: answer(["chanceId": ""]))
        #expect(stats.chanceId == "ch-2")
        stats.recordHttp(path: "peek", response: answer(["chanceId": "ch-3"]))
        #expect(stats.chanceId == "ch-3")
    }
}
