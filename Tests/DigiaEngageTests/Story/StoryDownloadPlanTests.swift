import Foundation
import Testing

@testable import DigiaEngage

/// The issue rules as listed in `StoryDownloadPlan`: window shape per open
/// position, cold start, slow network, no-Range server, images, and swipe
/// recomputation. `Item(isVideo:)` is the whole input; no JSON mapping is
/// tested (D4). Same case list as Android's `StoryDownloadPlanTest`, same
/// inputs, same expected outputs.
@Suite("StoryDownloadPlan", .tags(.media, .unit))
struct StoryDownloadPlanTests {
    private let video = StoryDownloadPlan.Item(isVideo: true)
    private let image = StoryDownloadPlan.Item(isVideo: false)

    private func player(_ index: Int, _ priority: PoolPriority) -> StoryDownloadPlan.Action {
        .player(index: index, priority: priority)
    }

    private func firstBytes(_ index: Int) -> StoryDownloadPlan.Action {
        .firstBytes(index: index)
    }

    private func wholeFile(_ index: Int) -> StoryDownloadPlan.Action {
        .wholeFile(index: index)
    }

    // Fails if the cold start plans neighbours: the `if !firstFrameShown`
    // early return in `plan`.
    @Test("cold start plans only the current player")
    func coldStartPlansOnlyTheCurrentPlayer() {
        let stories = [video, video, video]

        #expect(StoryDownloadPlan.plan(
            stories: stories, currentIndex: 0, firstFrameShown: false, slowNetwork: false
        ) == [player(0, .viewerPage)])
    }

    // Fails if the forward window shape changes: `player(n+1)` /
    // `firstBytes(n+2)` in `plan`.
    @Test("open at zero plans the player and forward window")
    func openAtZeroPlansThePlayerAndForwardWindow() {
        let stories = [video, video, video, video]

        #expect(StoryDownloadPlan.plan(
            stories: stories, currentIndex: 0, firstFrameShown: true, slowNetwork: false
        ) == [player(0, .viewerPage), player(1, .viewerNext), firstBytes(2)])
    }

    // Fails if the middle order changes: current, next player, next bytes,
    // previous player, previous bytes — the serving order in `plan`. The
    // backward bytes are `n-2` (symmetric with the last case), not the
    // issue text's `n-3`.
    @Test("middle plans both sides in serving order")
    func middlePlansBothSidesInServingOrder() {
        let stories = [video, video, video, video, video]

        #expect(StoryDownloadPlan.plan(
            stories: stories, currentIndex: 2, firstFrameShown: true, slowNetwork: false
        ) == [
            player(2, .viewerPage),
            player(3, .viewerNext),
            firstBytes(4),
            player(1, .viewerPrev),
            firstBytes(0),
        ])
    }

    // Fails if the last-story branch is lost: the
    // `currentIndex == stories.endIndex - 1` line.
    @Test("last plans backward only")
    func lastPlansBackwardOnly() {
        let stories = [video, video, video, video, video]

        #expect(StoryDownloadPlan.plan(
            stories: stories, currentIndex: 4, firstFrameShown: true, slowNetwork: false
        ) == [
            player(4, .viewerPage),
            player(3, .viewerPrev),
            firstBytes(2),
        ])
    }

    // Fails if slow plans more than the next first bytes: the early
    // `slowNetwork` return.
    @Test("slow network plans only the next first bytes")
    func slowNetworkPlansOnlyTheNextFirstBytes() {
        let stories = [video, video, video, video, video]

        #expect(StoryDownloadPlan.plan(
            stories: stories, currentIndex: 2, firstFrameShown: true, slowNetwork: true
        ) == [player(2, .viewerPage), firstBytes(3)])
    }

    // Fails if no-Range byte actions stay FirstBytes: without Range only n±1
    // warm, as whole files, and the n±2 byte actions are dropped — the
    // `!rangeSupported` branch.
    @Test("no-range server warms whole files only for neighbours")
    func noRangeServerWarmsWholeFilesOnlyForNeighbours() {
        let stories = [video, video, video, video, video]

        #expect(StoryDownloadPlan.plan(
            stories: stories, currentIndex: 2, firstFrameShown: true,
            slowNetwork: false, rangeSupported: false
        ) == [
            player(2, .viewerPage),
            player(3, .viewerNext),
            player(1, .viewerPrev),
        ])
        #expect(StoryDownloadPlan.plan(
            stories: stories, currentIndex: 2, firstFrameShown: true,
            slowNetwork: true, rangeSupported: false
        ) == [player(2, .viewerPage), wholeFile(3)])
    }

    // Fails if images get players or first bytes: an image at any slot plans
    // WholeFile — the isVideo checks in `playerOrWholeFile`/`byteOrWholeFile`.
    @Test("images plan whole files instead of players and first bytes")
    func imagesPlanWholeFilesInsteadOfPlayersAndFirstBytes() {
        let stories = [video, image, video]

        #expect(StoryDownloadPlan.plan(
            stories: stories, currentIndex: 0, firstFrameShown: true, slowNetwork: false
        ) == [player(0, .viewerPage), wholeFile(1), firstBytes(2)])
        #expect(StoryDownloadPlan.plan(
            stories: [image, video], currentIndex: 0,
            firstFrameShown: false, slowNetwork: false
        ) == [wholeFile(0)])
    }

    // Fails if the middle-of-the-list window loses its backward player: a swipe to 1 plans the
    // next player, its bytes and the previous player (`at(0)` and `at(2)` are the open-at-zero and
    // middle cases above).
    @Test("a swipe to the second story plans its own window")
    func aSwipeToTheSecondStoryPlansItsOwnWindow() {
        #expect(StoryDownloadPlan.plan(
            stories: [video, video, video, video, video], currentIndex: 1, firstFrameShown: true, slowNetwork: false
        ) == [
            player(1, .viewerPage),
            player(2, .viewerNext),
            firstBytes(3),
            player(0, .viewerPrev),
        ])
    }

    // Fails if an empty list or a bad index throws: the
    // `isEmpty || !indices.contains` guard.
    @Test("empty stories and out-of-range index plan nothing")
    func emptyStoriesAndOutOfRangeIndexPlanNothing() {
        #expect(StoryDownloadPlan.plan(
            stories: [], currentIndex: 0, firstFrameShown: true, slowNetwork: false
        ) == [])
        #expect(StoryDownloadPlan.plan(
            stories: [video], currentIndex: 9, firstFrameShown: true, slowNetwork: false
        ) == [])
    }
}
