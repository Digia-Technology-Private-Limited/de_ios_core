import Foundation
import Testing

@testable import DigiaEngage

// The two rail rules (T8) no surface shows, on `StoryRailState` alone. The turns, a card the pool
// evicted keeping its place, and a failed card leaving the rotation are proved through the mounted
// rail in `StoryPageTests`. Here: a lone refused card waits for the restart (the `skip` line changes
// nothing a mounted rail shows, as `MediaVideo` retries on its own when the app returns), and a
// settled scroll keeps the playing card (a test-driven scroll does not reach the rail's settle).

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

    // Guards `return updated.reconcileActive()` in `StoryRailState.visibilityChanged`.
    @Test("a settled scroll keeps the playing card while it is still in view")
    func settledScrollKeepsThePlayingCard() {
        let items = Array(repeating: Self.video, count: 5)
        let visibility = StoryRailVisibility(slotVisible: true, cardFractions: [0: 1, 1: 1, 2: 1, 3: 0, 4: 0])
        let state = StoryRailState()
            .lifecycleChanged(active: true)
            .visibilityChanged(items: items, visibility: visibility)
            .complete(index: 0)
        #expect(playing(state, 5) == [1], "card 1 has the turn")

        let settled = state.visibilityChanged(items: items, visibility: visibility)

        #expect(playing(settled, 5) == [1], "card 1 keeps playing")
        #expect(settled.restartGeneration == state.restartGeneration, "its window is not replayed")
    }
}
