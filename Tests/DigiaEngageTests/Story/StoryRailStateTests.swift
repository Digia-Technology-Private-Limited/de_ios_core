import Foundation
import Testing

@testable import DigiaEngage

// The rail's schedule (T8), on `StoryRailState` alone: the cards on screen take turns, one at a
// time; a refused or evicted card skips its turn and stays in the rotation, a lone refused card
// waits for the next restart, and only a real failure removes a card for the session.

@Suite("Story rail", .tags(.inline, .media, .unit))
struct StoryRailStateTests {
    private static let video = StoryItemConfig(type: .video, url: "https://rail.test/v.mp4", duration: nil)
    private static let image = StoryItemConfig(type: .image, url: "https://rail.test/i.jpg", duration: nil)

    /// A rail on screen with every listed card fully visible, in the foreground.
    private func rail(
        items: [StoryItemConfig], visible: [Int]
    ) -> StoryRailState {
        StoryRailState()
            .lifecycleChanged(active: true)
            .visibilityChanged(
                items: items,
                visibility: StoryRailVisibility(
                    slotVisible: true,
                    cardFractions: Dictionary(uniqueKeysWithValues: visible.map { ($0, 1.0) })
                )
            )
    }

    private func playing(_ state: StoryRailState, _ count: Int) -> [Int] {
        (0..<count).filter { state.decision(index: $0).play }
    }

    // Guards `updated.activeIndex = nextStoryRailIndex(eligible: playable, afterIndex: index)` in
    // `StoryRailState.complete`.
    @Test("the cards on screen take turns and the rotation wraps past the last one")
    func cardsTakeTurns() {
        let items = [Self.video, Self.image, Self.video, Self.video]
        var state = rail(items: items, visible: [0, 1, 2, 3])
        var turns: [[Int]] = [playing(state, 4)]
        for _ in 0..<3 {
            state = state.complete(index: state.activeIndex ?? -1)
            turns.append(playing(state, 4))
        }

        #expect(turns == [[0], [2], [3], [0]])
        #expect(!state.decision(index: 0).repeatWindow, "a rotation hands over instead of looping")
    }

    // Guards `StoryRailState.skip` (the turn moves on, the card stays
    // playable) and `updated.skipped = []` in `complete` (it gets its next turn).
    @Test("a card the pool refused skips its turn and stays in the rotation")
    func refusedCardSkipsItsTurn() {
        let items = [Self.video, Self.video, Self.video]
        var state = rail(items: items, visible: [0, 1, 2])

        state = state.skip(index: 0)
        #expect(playing(state, 3) == [1], "the next card plays now")
        #expect(state.playable.contains(0), "the refused card is still in the rotation")

        state = state.complete(index: 1)
        state = state.complete(index: 2)
        #expect(playing(state, 3) == [0], "the refused card gets its next turn")
    }

    // Guards `nextStoryRailIndex(eligible: updated.turnCandidates, ...)` in `StoryRailState.skip`:
    // a lone card the pool keeps refusing is not tried again every frame.
    @Test("a lone refused card waits for the next rail restart")
    func loneRefusedCardWaitsForRestart() {
        let items = [Self.video, Self.image]
        var state = rail(items: items, visible: [0, 1])
        #expect(playing(state, 2) == [0])

        state = state.skip(index: 0)
        #expect(playing(state, 2).isEmpty, "nothing is scheduled until the rail restarts")

        state = state.lifecycleChanged(active: false).lifecycleChanged(active: true)
        #expect(playing(state, 2) == [0], "the restart tries it again")
    }

    // Guards `eligible.subtracting(failed)` in `StoryRailState.playable`: a failure outlives every
    // restart, a refusal does not.
    @Test("only a real playback failure removes a card for the session")
    func failureRemovesTheCard() {
        let items = [Self.video, Self.video]
        var state = rail(items: items, visible: [0, 1])

        state = state.fail(index: 0)
        #expect(playing(state, 2) == [1])

        state = state.lifecycleChanged(active: false).lifecycleChanged(active: true)
        state = state.complete(index: 1)
        #expect(playing(state, 2) == [1], "the failed card never comes back, even after a restart")
        #expect(state.decision(index: 1).repeatWindow, "the one card left loops in place")
    }
}
