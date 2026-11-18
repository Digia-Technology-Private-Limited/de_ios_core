import Testing
@testable import DigiaEngage

struct GameWindowStatsTests {
    final class Clock: @unchecked Sendable { var now: Int64 = 0 }

    private func answer(_ response: [String: Any]) -> [String: Any] {
        ["isSuccess": true, "data": ["response": response]]
    }

    @Test func dwellCountsOnlyForegroundTimeAfterTheGameShowed() {
        let clock = Clock()
        let stats = GameWindowStats(openChanceId: "open-chance") { clock.now }
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

    @Test func playsCountOutcomesRefusalAndChanceFollowTheLatestPlayOrPeek() {
        let stats = GameWindowStats(openChanceId: "open-chance") { 0 }
        stats.recordHttp(path: "play", request: ["chanceId": "c1"], response: answer(["outcomeKey": "win"]))
        stats.recordHttp(path: "peek", request: ["chanceId": "c2"], response: answer(["outcomeKey": "win", "refused": "exhausted"]))
        stats.recordHttp(path: "play", request: ["chanceId": "c2"], response: answer(["refused": "cooldown"]))
        stats.recordHttp(path: "claim", request: ["chanceId": "other"], response: answer(["outcomeKey": "x"]))
        stats.recordHttp(path: "play", request: ["chanceId": "c3"], response: answer(["outcomeKey": "lose"]))

        #expect(stats.plays == 2)
        #expect(stats.playRefused == "cooldown")
        #expect(stats.chanceId == "c3")
    }
}
