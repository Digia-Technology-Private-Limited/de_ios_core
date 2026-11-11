import Foundation
import Testing

@testable import DigiaEngage

/// The two plan rules no surface can reach. The window shapes, the cold start, the slow network and
/// images are proved through the viewer in `StoryPageTests` (the pool's ranks and the origin's
/// byte ranges). `StoryViewer` never passes `rangeSupported: false`, and it clamps its index and
/// returns on no stories before it plans, so the plan's own guards stay here.
@Suite("StoryDownloadPlan", .tags(.media, .unit))
struct StoryDownloadPlanTests {
    private let video = StoryDownloadPlan.Item(isVideo: true)

    private func player(_ index: Int, _ priority: PoolPriority) -> StoryDownloadPlan.Action {
        .player(index: index, priority: priority)
    }

    private func wholeFile(_ index: Int) -> StoryDownloadPlan.Action {
        .wholeFile(index: index)
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
