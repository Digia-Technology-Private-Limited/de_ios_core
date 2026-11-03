import Foundation
import Testing

@testable import DigiaEngage

/// StoryRail owns the 75% start / 25% stop visibility rule and take-turns (T10): the rail's
/// public entry is `visibilityChanged`, play/pause reads back through `decision`. A shipped
/// `simultaneous` wire value parses (compat) but still takes turns (D7). Same cases as
/// Android's `StoryRailThresholdTest`.
@Suite("StoryRail", .tags(.media, .unit, .inline))
struct StoryRailTests {
    private func video(url: String = "https://media.test/clip.mp4") -> StoryItemConfig {
        StoryItemConfig(type: .video, url: url, duration: nil)
    }

    private func playing(
        items: [StoryItemConfig]? = nil
    ) -> StoryRailState {
        let list = items ?? [video(), video()]
        return StoryRailState(lifecycleActive: true)
            .visibilityChanged(
                items: list,
                slotVisible: true,
                visibleFractions: [0: 1, 1: 1],
                settled: true
            )
    }

    // Fails if the start line moves: the `>= startWhenVisible` comparison in
    // `updateStoryRailEligibility`. 0.75 starts; 0.74 does not.
    @Test("a card starts only once three quarters visible")
    func cardStartsOnlyOnceThreeQuartersVisible() {
        let items = [video(), video()]

        let started = StoryRailState(lifecycleActive: true)
            .visibilityChanged(items: items, slotVisible: true,
                               visibleFractions: [0: 0.75, 1: 0.74], settled: true)

        #expect(started.decision(index: 0).play)
        #expect(!started.decision(index: 1).play)
    }

    // Fails if the stop line moves: the `< stopBelow` removal in
    // `updateStoryRailEligibility`. Hysteresis: started at 0.8, still playing at exactly 0.25,
    // stopped just below it.
    @Test("a playing card stops only once below one quarter visible")
    func playingCardStopsOnlyOnceBelowOneQuarterVisible() {
        let items = [video()]
        let started = StoryRailState(lifecycleActive: true)
            .visibilityChanged(items: items, slotVisible: true,
                               visibleFractions: [0: 0.8], settled: true)
        #expect(started.decision(index: 0).play)

        let atQuarter = started.visibilityChanged(
            items: items, slotVisible: true, visibleFractions: [0: 0.25], settled: false)
        #expect(atQuarter.decision(index: 0).play)

        let belowQuarter = atQuarter.visibilityChanged(
            items: items, slotVisible: true, visibleFractions: [0: 0.24], settled: false)
        #expect(!belowQuarter.decision(index: 0).play)
    }

    // Fails if the documented fractions move: the `storyRailStartWhenVisible` /
    // `storyRailStopBelow` declarations (the single ownership of the 75/25 rule).
    @Test("the documented fractions are the constants")
    func documentedFractionsAreTheConstants() {
        #expect(storyRailStartWhenVisible == 0.75)
        #expect(storyRailStopBelow == 0.25)
    }

    // Fails if take-turns breaks: `nextStoryRailIndex` (first eligible wins, then wraps) as
    // driven by `StoryRailState.complete`. Exactly one card plays at a time.
    @Test("take turns plays one card at a time then hands over")
    func takeTurnsPlaysOneCardAtATime() {
        let state = playing()

        #expect(state.activeIndex == 0)
        #expect(state.decision(index: 0).play)
        #expect(!state.decision(index: 1).play)

        let next = state.complete(index: 0)
        #expect(next.activeIndex == 1)
        #expect(!next.decision(index: 0).play)
        #expect(next.decision(index: 1).play)

        #expect(next.complete(index: 1).activeIndex == 0)
    }

    // Fails if a shipped `simultaneous` campaign stops parsing (the
    // `== "sequential"` line in `InlineStoryConfig.fromJson`) or starts playing every card at
    // once (the single-active scheduling in `StoryRailState`): the wire value is kept, the rail
    // still takes turns (D7 back-compat).
    @Test("a simultaneous campaign parses but still takes turns")
    func simultaneousCampaignParsesButStillTakesTurns() {
        func config(mode: String) -> InlineStoryConfig? {
            InlineStoryConfig.fromJson([
                "slotKey": "rail",
                "thumbnailVideoPlayback": mode,
                "items": [
                    ["url": "https://media.test/a.mp4", "type": "video"],
                    ["url": "https://media.test/b.mp4", "type": "video"],
                ],
            ])
        }

        #expect(config(mode: "simultaneous")?.thumbnailVideoPlayback == .simultaneous)
        #expect(config(mode: "sequential")?.thumbnailVideoPlayback == .sequential)

        let items = config(mode: "simultaneous")?.items ?? []
        let state = StoryRailState(lifecycleActive: true)
            .visibilityChanged(items: items, slotVisible: true,
                               visibleFractions: [0: 1, 1: 1], settled: true)
        #expect(state.activeIndex == 0)
        #expect(state.decision(index: 0).play)
        #expect(!state.decision(index: 1).play)
    }

    // Fails if the pool key shape changes: the `story-<index>` / `<ns>/story-<index>` contract
    // the viewer reuses on handover (`pageKey`).
    @Test("pool keys namespace by campaign")
    func poolKeysNamespaceByCampaign() {
        #expect(storyPoolKey(namespace: nil, index: 0) == "story-0")
        #expect(storyPoolKey(namespace: "  ", index: 0) == "story-0")
        #expect(storyPoolKey(namespace: "test_inline_story", index: 2) == "test_inline_story/story-2")
    }

    // Fails if a failed card keeps the turn: `fail` removes it from `playable` and
    // `reconcileActive` moves the turn on.
    @Test("a failed card loses its turn")
    func failedCardLosesItsTurn() {
        let state = playing().fail(index: 0)
        #expect(state.activeIndex == 1)
        #expect(!state.decision(index: 0).play)
        #expect(state.decision(index: 1).play)
    }
}
