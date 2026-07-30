import Foundation

let thumbnailPlaybackEntryVisibility = 0.75
let thumbnailPlaybackExitVisibility = 0.25
let thumbnailPlaybackStallSeconds = 10.0

func updateThumbnailPlaybackEligibility(
    current: Set<Int>,
    visibleFractions: [Int: Double],
    items: [StoryItemConfig]
) -> Set<Int> {
    var next = current.filter { index in
        guard items.indices.contains(index) else { return false }
        let item = items[index]
        return item.type == .video
            && !item.url.isEmpty
            && (visibleFractions[index] ?? 0) >= thumbnailPlaybackExitVisibility
    }
    for (index, rawFraction) in visibleFractions {
        guard items.indices.contains(index) else { continue }
        let item = items[index]
        guard item.type == .video, !item.url.isEmpty else { continue }
        let fraction = min(max(rawFraction, 0), 1)
        if fraction >= thumbnailPlaybackEntryVisibility {
            next.insert(index)
        }
    }
    return next
}

func thumbnailPlayerLayerCanReveal(
    shouldPlay: Bool,
    startPrepared: Bool,
    playerLayerReady: Bool,
    seekInProgress: Bool,
    positionMs: Int64,
    effectiveStartMs: Int64
) -> Bool {
    shouldPlay
        && startPrepared
        && playerLayerReady
        && !seekInProgress
        && positionMs > effectiveStartMs + 10
}

func nextThumbnailPlaybackIndex(
    eligible: Set<Int>,
    afterIndex: Int?
) -> Int? {
    let ordered = eligible.sorted()
    guard let first = ordered.first else { return nil }
    guard let afterIndex else { return first }
    return ordered.first(where: { $0 > afterIndex }) ?? first
}

func shouldRepeatThumbnailPlaybackWindow(
    mode: ThumbnailVideoPlaybackMode,
    eligibleVideoCount: Int
) -> Bool {
    mode == .simultaneous || eligibleVideoCount == 1
}

func effectiveThumbnailStartMs(
    item: StoryItemConfig,
    naturalDurationMs: Int64
) -> Int64 {
    let start = max(item.thumbnailPlayback.startTimeMs, 0)
    return naturalDurationMs > 0 && start >= naturalDurationMs ? 0 : start
}

func thumbnailPlaybackWindowEnded(
    item: StoryItemConfig,
    currentPositionMs: Int64,
    effectiveStartMs: Int64
) -> Bool {
    guard item.thumbnailPlayback.durationMode == .fixed,
          let durationMs = item.thumbnailPlayback.durationMs
    else {
        return false
    }
    return currentPositionMs - effectiveStartMs >= durationMs
}
