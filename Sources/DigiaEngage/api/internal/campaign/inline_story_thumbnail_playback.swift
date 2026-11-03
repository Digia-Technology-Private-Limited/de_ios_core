import Foundation

/// The rail's measured visibility: whether the slot itself is on screen and how much of each
/// card (by story index) is visible. Geometry collection stays in SwiftUI; the resulting
/// measurement enters `StoryRailState` through `visibilityChanged`.
struct StoryRailVisibility: Equatable {
    let slotVisible: Bool
    let cardFractions: [Int: Double]
}

/// Measures how much of the rail and each card is visible in `viewport`. Pure geometry: the
/// 75/25 scheduling rule itself lives in `StoryRailState` (`StoryRail.swift`).
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

// MARK: - Thumbnail window helpers (owned by `StoryVideoPlayback`, lane E/T9)

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
