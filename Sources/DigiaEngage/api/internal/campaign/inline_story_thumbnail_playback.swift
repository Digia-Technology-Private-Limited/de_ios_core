import Foundation

// Wait until most of a card is visible before starting it.
let startPlaybackWhenVisible = 0.75

// Once started, keep playing until the card is mostly off-screen.
let stopPlaybackWhenBelow = 0.25

struct StoryRailVisibility: Equatable {
    let slotVisible: Bool
    let cardFractions: [Int: Double]
}

func storyRailVisibility(
    rail: CGRect?,
    cards: [Int: CGRect],
    viewport: CGRect
) -> StoryRailVisibility {
    guard let rail,
          !rail.isNull,
          !rail.isEmpty,
          !viewport.isNull,
          !viewport.isEmpty
    else {
        return StoryRailVisibility(slotVisible: false, cardFractions: [:])
    }

    let visibleRail = rail.intersection(viewport)
    let slotVisible = !visibleRail.isNull && !visibleRail.isEmpty
    var fractions: [Int: Double] = [:]
    for (index, card) in cards where !card.isNull && !card.isEmpty {
        let visible = card.intersection(rail).intersection(viewport)
        let totalArea = card.width * card.height
        let visibleArea = visible.isNull || visible.isEmpty ? 0 : visible.width * visible.height
        fractions[index] = totalArea > 0
            ? min(max(Double(visibleArea / totalArea), 0), 1)
            : 0
    }
    return StoryRailVisibility(slotVisible: slotVisible, cardFractions: fractions)
}

func updateThumbnailPlaybackEligibility(
    current: Set<Int>,
    slotVisible: Bool = true,
    visibleFractions: [Int: Double],
    items: [StoryItemConfig],
    startWhenVisible: Double = startPlaybackWhenVisible,
    stopWhenBelow: Double = stopPlaybackWhenBelow
) -> Set<Int> {
    precondition(startWhenVisible > stopWhenBelow)
    guard slotVisible else { return current }
    var next = current.filter { index in
        guard items.indices.contains(index) else { return false }
        let item = items[index]
        return item.type == .video
            && !item.url.isEmpty
            && (visibleFractions[index] ?? 0) >= stopWhenBelow
    }
    for (index, rawFraction) in visibleFractions {
        guard items.indices.contains(index) else { continue }
        let item = items[index]
        guard item.type == .video, !item.url.isEmpty else { continue }
        let fraction = min(max(rawFraction, 0), 1)
        if fraction >= startWhenVisible {
            next.insert(index)
        }
    }
    return next
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

func shouldFallbackToZeroThumbnailStart(
    effectiveStartMs: Int64,
    naturalDurationMs: Int64
) -> Bool {
    effectiveStartMs > 0
        && naturalDurationMs > 0
        && effectiveStartMs >= naturalDurationMs
}

enum ThumbnailSeekRecoveryAction: Equatable {
    case complete
    case retryAtZero
    case fail
}

func thumbnailSeekRecoveryAction(
    succeeded: Bool,
    retryAtZero: Bool,
    effectiveStartMs: Int64
) -> ThumbnailSeekRecoveryAction {
    if succeeded { return .complete }
    if retryAtZero, effectiveStartMs != 0 { return .retryAtZero }
    return .fail
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
