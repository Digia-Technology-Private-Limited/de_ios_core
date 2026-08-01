@testable import DigiaEngage
import CoreGraphics
import Testing

@MainActor
@Suite("Inline story thumbnail playback")
struct InlineStoryThumbnailPlaybackTests {
    @Test("defaults preserve legacy simultaneous behavior")
    func defaults() throws {
        let config = try #require(InlineStoryConfig.fromJson([
            "slotKey": "home",
            "items": [[
                "type": "video",
                "url": "https://example.com/story.mp4",
            ]],
        ]))

        #expect(config.thumbnailVideoPlayback == .simultaneous)
        #expect(config.items[0].thumbnailPlayback.startTimeMs == 0)
        #expect(config.items[0].thumbnailPlayback.durationMode == .full)
        #expect(config.items[0].thumbnailPlayback.durationMs == nil)
    }

    @Test("parses sequential fixed windows")
    func parsesSequentialFixedWindow() throws {
        let config = try #require(InlineStoryConfig.fromJson([
            "slotKey": "home",
            "thumbnailVideoPlayback": "sequential",
            "items": [[
                "type": "video",
                "url": "https://example.com/story.mp4",
                "thumbnailPlayback": [
                    "startTimeMs": 42_000,
                    "durationMode": "fixed",
                    "durationMs": 5_000,
                ],
            ]],
        ]))

        #expect(config.thumbnailVideoPlayback == .sequential)
        #expect(config.items[0].thumbnailPlayback.startTimeMs == 42_000)
        #expect(config.items[0].thumbnailPlayback.durationMode == .fixed)
        #expect(config.items[0].thumbnailPlayback.durationMs == 5_000)
    }

    @Test("invalid values fall back safely")
    func rejectsInvalidValues() throws {
        let config = try #require(InlineStoryConfig.fromJson([
            "slotKey": "home",
            "thumbnailVideoPlayback": "future-mode",
            "items": [[
                "type": "video",
                "url": "https://example.com/story.mp4",
                "thumbnailPlayback": [
                    "startTimeMs": -1,
                    "durationMode": "fixed",
                    "durationMs": 0,
                ],
            ]],
        ]))

        #expect(config.thumbnailVideoPlayback == .simultaneous)
        #expect(config.items[0].thumbnailPlayback.startTimeMs == 0)
        #expect(config.items[0].thumbnailPlayback.durationMode == .full)
        #expect(config.items[0].thumbnailPlayback.durationMs == nil)
    }

    @Test("image thumbnail reuses image and BlurHash fields")
    func parsesImageThumbnail() throws {
        let item = try #require(StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/story.mp4",
            "thumbnail": [
                "type": "image",
                "src": ["imageSrc": "https://example.com/poster.jpg"],
                "fit": "contain",
                "placeholder": [
                    "type": "blurhash",
                    "blurHash": "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
                ],
            ],
        ]))

        guard case let .image(source, fit, placeholder) = item.thumbnail else {
            Issue.record("Expected an image thumbnail")
            return
        }
        #expect(source == "https://example.com/poster.jpg")
        #expect(fit == .contain)
        #expect(placeholder?.type == .blurhash)
        #expect(placeholder?.blurHash == "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
    }

    @Test("color thumbnail parses and malformed thumbnails keep legacy fallback")
    func parsesColorAndRejectsMalformedThumbnail() throws {
        let color = try #require(StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/story.mp4",
            "thumbnail": ["type": "color", "color": "#1A1A1A"],
        ]))
        let malformed = try #require(StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/story.mp4",
            "thumbnail": ["type": "image", "src": [:]],
        ]))

        guard case let .color(value) = color.thumbnail else {
            Issue.record("Expected a color thumbnail")
            return
        }
        #expect(value == "#1A1A1A")
        #expect(malformed.thumbnail == nil)
        #expect(StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/video.mp4",
            "thumbnail": ["type": "image", "src": ["imageSrc": "not a URL"]],
        ])?.thumbnail != nil)
        #expect(StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/video.mp4",
            "thumbnail": ["type": "color", "color": "blue-ish"],
        ])?.thumbnail != nil)
    }

    @Test("full playback ignores irrelevant duration")
    func fullPlaybackIgnoresDuration() {
        let playback = StoryThumbnailPlaybackConfig.fromJson([
            "durationMode": "full",
            "durationMs": 5_000,
        ])

        #expect(playback.durationMode == .full)
        #expect(playback.durationMs == nil)
    }

    @Test("eligibility uses separate start and stop thresholds and preserves a hidden slot")
    func eligibilityUsesVisibilityThresholds() throws {
        let video = try #require(StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/story.mp4",
        ]))
        let image = try #require(StoryItemConfig.fromJson([
            "type": "image",
            "url": "https://example.com/story.png",
        ]))
        let entered = updateThumbnailPlaybackEligibility(
            current: [],
            visibleFractions: [0: 0.6, 1: 1],
            items: [video, image],
            startWhenVisible: 0.6,
            stopWhenBelow: 0.4
        )
        let retained = updateThumbnailPlaybackEligibility(
            current: entered,
            visibleFractions: [0: 0.4],
            items: [video, image],
            startWhenVisible: 0.6,
            stopWhenBelow: 0.4
        )
        let hidden = updateThumbnailPlaybackEligibility(
            current: retained,
            slotVisible: false,
            visibleFractions: [:],
            items: [video, image],
            startWhenVisible: 0.6,
            stopWhenBelow: 0.4
        )
        let exited = updateThumbnailPlaybackEligibility(
            current: hidden,
            visibleFractions: [0: 0.399],
            items: [video, image],
            startWhenVisible: 0.6,
            stopWhenBelow: 0.4
        )

        #expect(entered == [0])
        #expect(retained == [0])
        #expect(hidden == [0])
        #expect(exited.isEmpty)
    }

    @Test("settled scroll includes every card above threshold and starts at lowest index")
    func settledScrollStartsAtFirstEligibleIndex() throws {
        let videos = try (0..<3).map { index in
            try #require(StoryItemConfig.fromJson([
                "type": "video",
                "url": "https://example.com/story-\(index).mp4",
            ]))
        }
        let eligible = updateThumbnailPlaybackEligibility(
            current: [],
            visibleFractions: [0: 0.8, 1: 1, 2: 1],
            items: videos
        )

        #expect(eligible == [0, 1, 2])
        #expect(nextThumbnailPlaybackIndex(eligible: eligible, afterIndex: nil) == 0)
    }

    @Test("rail visibility uses the hosting viewport and collapses safely")
    func railVisibilityUsesHostingViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 500, height: 300)
        let visible = storyRailVisibility(
            rail: CGRect(x: 0, y: 100, width: 700, height: 200),
            cards: [
                0: CGRect(x: 0, y: 100, width: 200, height: 200),
                1: CGRect(x: 450, y: 100, width: 200, height: 200),
                2: CGRect(x: 550, y: 100, width: 100, height: 200),
            ],
            viewport: viewport
        )
        let collapsed = storyRailVisibility(
            rail: .zero,
            cards: [0: CGRect(x: 0, y: 0, width: 200, height: 200)],
            viewport: viewport
        )

        #expect(visible.slotVisible)
        #expect(visible.cardFractions[0] == 1)
        #expect(visible.cardFractions[1] == 0.25)
        #expect(visible.cardFractions[2] == 0)
        #expect(!collapsed.slotVisible)
        #expect(collapsed.cardFractions.isEmpty)
    }

    @Test("helpers wrap and bound configured windows")
    func playbackHelpers() throws {
        let item = try #require(fixedWindowItem())

        #expect(nextThumbnailPlaybackIndex(eligible: [1, 3], afterIndex: 1) == 3)
        #expect(nextThumbnailPlaybackIndex(eligible: [1, 3], afterIndex: 3) == 1)
        #expect(shouldRepeatThumbnailPlaybackWindow(mode: .simultaneous, eligibleVideoCount: 3))
        #expect(shouldRepeatThumbnailPlaybackWindow(mode: .sequential, eligibleVideoCount: 1))
        #expect(!shouldRepeatThumbnailPlaybackWindow(mode: .sequential, eligibleVideoCount: 2))
        #expect(effectiveThumbnailStartMs(item: item, naturalDurationMs: 40_000) == 0)
        #expect(thumbnailPlaybackWindowEnded(
            item: item,
            currentPositionMs: 47_000,
            effectiveStartMs: 42_000
        ))
    }

    @Test("unknown duration defers validation until metadata becomes known")
    func lateDurationValidation() {
        #expect(!shouldFallbackToZeroThumbnailStart(
            effectiveStartMs: 42_000,
            naturalDurationMs: 0
        ))
        #expect(shouldFallbackToZeroThumbnailStart(
            effectiveStartMs: 42_000,
            naturalDurationMs: 30_000
        ))
        #expect(!shouldFallbackToZeroThumbnailStart(
            effectiveStartMs: 20_000,
            naturalDurationMs: 30_000
        ))
    }

    @Test("a failed nonzero seek retries once and a failed zero seek terminates")
    func seekRecoveryPolicy() {
        #expect(thumbnailSeekRecoveryAction(
            succeeded: true,
            retryAtZero: true,
            effectiveStartMs: 42_000
        ) == .complete)
        #expect(thumbnailSeekRecoveryAction(
            succeeded: false,
            retryAtZero: true,
            effectiveStartMs: 42_000
        ) == .retryAtZero)
        #expect(thumbnailSeekRecoveryAction(
            succeeded: false,
            retryAtZero: false,
            effectiveStartMs: 0
        ) == .fail)
    }

    @Test("only the scheduled explicit thumbnail owns a player")
    func explicitThumbnailAllocationPolicy() {
        #expect(shouldComposeThumbnailPlayer(
            hasExplicitThumbnail: false,
            scheduled: false
        ))
        #expect(shouldComposeThumbnailPlayer(
            hasExplicitThumbnail: true,
            scheduled: true
        ))
        #expect(!shouldComposeThumbnailPlayer(
            hasExplicitThumbnail: true,
            scheduled: false
        ))
    }

    @Test("layer stays hidden until the current seek advances")
    func layerWaitsForCurrentSeek() {
        #expect(!ThumbnailRevealState(
            shouldPlay: true,
            startPrepared: true,
            playerLayerReady: true,
            seekInProgress: true,
            effectiveStartMs: 42_000
        ).canReveal(at: 47_000))
        #expect(!ThumbnailRevealState(
            shouldPlay: true,
            startPrepared: true,
            playerLayerReady: true,
            seekInProgress: false,
            effectiveStartMs: 42_000
        ).canReveal(at: 42_000))
        #expect(ThumbnailRevealState(
            shouldPlay: true,
            startPrepared: true,
            playerLayerReady: true,
            seekInProgress: false,
            effectiveStartMs: 42_000
        ).canReveal(at: 42_011))
    }

    @Test("player identity tracks playback and placeholder configuration")
    func playerIdentityTracksConfiguration() throws {
        let original = try #require(fixedWindowItem(durationMs: 5_000))
        let changed = try #require(fixedWindowItem(durationMs: 6_000))
        let image = try #require(StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/story.mp4",
            "thumbnail": [
                "type": "image",
                "src": ["imageSrc": "https://example.com/poster.jpg"],
            ],
        ]))
        let color = try #require(StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/story.mp4",
            "thumbnail": ["type": "color", "color": "#1A1A1A"],
        ]))

        #expect(thumbnailPlayerIdentity(original) != thumbnailPlayerIdentity(changed))
        #expect(thumbnailPlayerIdentity(image) != thumbnailPlayerIdentity(color))
    }

    private func fixedWindowItem(durationMs: Int = 5_000) -> StoryItemConfig? {
        StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/story.mp4",
            "thumbnailPlayback": [
                "startTimeMs": 42_000,
                "durationMode": "fixed",
                "durationMs": durationMs,
            ],
        ])
    }
}
