import Foundation

// Wait until most of a card is visible before starting it.
let startPlaybackWhenVisible = 0.75

// Once started, keep playing until the card is mostly off-screen.
let stopPlaybackWhenBelow = 0.25

struct StoryRailVisibility: Equatable {
    let slotVisible: Bool
    let cardFractions: [Int: Double]
}

struct StoryThumbnailPlayerIdentity: Hashable {
    let itemType: StoryMediaType
    let url: String
    let playback: StoryThumbnailPlaybackIdentity
    let thumbnail: StoryThumbnailIdentity?

    var cacheKey: String {
        String(reflecting: self)
    }
}

struct StoryThumbnailPlaybackIdentity: Hashable {
    let startTimeMs: Int64
    let durationMode: StoryThumbnailDurationMode
    let durationMs: Int64?
}

enum StoryThumbnailIdentity: Hashable {
    case image(source: String, fit: StoryMediaFit, blurHash: String?)
    case color(String)
}

func thumbnailPlayerIdentity(_ item: StoryItemConfig) -> StoryThumbnailPlayerIdentity {
    StoryThumbnailPlayerIdentity(
        itemType: item.type,
        url: item.url,
        playback: StoryThumbnailPlaybackIdentity(
            startTimeMs: item.thumbnailPlayback.startTimeMs,
            durationMode: item.thumbnailPlayback.durationMode,
            durationMs:
                item.thumbnailPlayback.durationMode == .fixed
                    ? item.thumbnailPlayback.durationMs
                    : nil
        ),
        thumbnail: item.thumbnail.map { thumbnail in
            switch thumbnail {
            case let .image(source, fit, placeholder):
                .image(source: source, fit: fit, blurHash: placeholder?.blurHash)
            case let .color(value):
                .color(value)
            }
        }
    )
}

struct ThumbnailPlaybackViewState: Equatable {
    let eligible: Bool
    let scheduled: Bool
    let shouldPlay: Bool
    let canLoad: Bool
    let cachePriority: StoryVideoCachePriority?
    let mode: ThumbnailVideoPlaybackMode
    let playableIndices: Set<Int>
    let restartGeneration: Int
}

struct InlineStoryRailPlaybackState: Equatable {
    var eligibleIndices: Set<Int> = []
    var failedPlayerIdentities: [Int: StoryThumbnailPlayerIdentity] = [:]
    var sequentialActiveIndex: Int?
    var slotVisible = false
    var applicationActive = false
    var overlayOpen = false
    var restartGeneration = 0
}

enum InlineStoryRailPlaybackEvent {
    case configuration(items: [StoryItemConfig], mode: ThumbnailVideoPlaybackMode)
    case scrollStarted
    case scrollSettled(StoryRailVisibility)
    case applicationActive(Bool)
    case overlayChanged(Bool)
    case windowCompleted(Int)
    case failed(index: Int, identity: StoryThumbnailPlayerIdentity)
}

/// Owns every decision about which thumbnail is eligible, scheduled, and allowed to play.
/// Geometry collection stays in SwiftUI; the resulting measurement enters through one event.
struct InlineStoryRailPlaybackCoordinator {
    private(set) var state = InlineStoryRailPlaybackState()
    private var items: [StoryItemConfig]
    private var mode: ThumbnailVideoPlaybackMode

    init(items: [StoryItemConfig], mode: ThumbnailVideoPlaybackMode) {
        self.items = items
        self.mode = mode
    }

    var playableIndices: Set<Int> {
        Set(state.eligibleIndices.filter { index in
            guard items.indices.contains(index) else { return false }
            return state.failedPlayerIdentities[index] != thumbnailPlayerIdentity(items[index])
        })
    }

    var videoDemands: [StoryVideoCacheDemand] {
        guard state.applicationActive, state.slotVisible, !state.overlayOpen else { return [] }
        let playable = playableIndices
        if mode == .simultaneous {
            return playable.sorted().compactMap { demand(index: $0, priority: .eligible) }
        }

        guard let activeIndex = state.sequentialActiveIndex,
              let active = demand(index: activeIndex, priority: .scheduled) else { return [] }
        var demands = [active]
        if playable.count > 1,
           let lookAheadIndex = nextThumbnailPlaybackIndex(
               eligible: playable,
               afterIndex: activeIndex
           ),
           lookAheadIndex != activeIndex,
           let lookAhead = demand(index: lookAheadIndex, priority: .lookAhead) {
            demands.append(lookAhead)
        }
        return demands
    }

    func playbackState(for index: Int) -> ThumbnailPlaybackViewState {
        let playable = playableIndices
        let eligible = playable.contains(index)
        let scheduled = eligible && isScheduled(index)
        return ThumbnailPlaybackViewState(
            eligible: eligible,
            scheduled: scheduled,
            shouldPlay: scheduled
                && state.applicationActive
                && state.slotVisible
                && !state.overlayOpen,
            canLoad: state.applicationActive,
            cachePriority: cachePriority(for: index, playable: playable),
            mode: mode,
            playableIndices: playable,
            restartGeneration: state.restartGeneration
        )
    }

    mutating func send(_ event: InlineStoryRailPlaybackEvent) {
        switch event {
        case let .configuration(nextItems, nextMode):
            let previousItems = items
            items = nextItems
            mode = nextMode
            state.eligibleIndices = state.eligibleIndices.filter { index in
                previousItems.indices.contains(index)
                    && nextItems.indices.contains(index)
                    && thumbnailPlayerIdentity(previousItems[index])
                        == thumbnailPlayerIdentity(nextItems[index])
            }
            state.failedPlayerIdentities = state.failedPlayerIdentities.filter { index, identity in
                nextItems.indices.contains(index)
                    && thumbnailPlayerIdentity(nextItems[index]) == identity
            }
            reconcileActive()

        case .scrollStarted:
            state.slotVisible = false

        case let .scrollSettled(visibility):
            state.slotVisible = visibility.slotVisible
            // A settled scroll is a new playback session. Rebuild from no previous eligibility,
            // then select the lowest eligible Campaign index rather than resuming.
            // Clear UI failures too; the file cache still blocks network retries for five minutes.
            state.failedPlayerIdentities = [:]
            state.eligibleIndices = updateThumbnailPlaybackEligibility(
                current: [],
                slotVisible: visibility.slotVisible,
                visibleFractions: visibility.cardFractions,
                items: items
            )
            restartFromFirst()

        case let .applicationActive(active):
            let wasActive = state.applicationActive
            state.applicationActive = active
            if active, !wasActive {
                restartFromFirst()
            }

        case let .overlayChanged(open):
            let wasOpen = state.overlayOpen
            state.overlayOpen = open
            if wasOpen, !open {
                restartFromFirst()
            }

        case let .windowCompleted(index):
            guard mode == .sequential,
                  state.sequentialActiveIndex == index else { return }
            state.sequentialActiveIndex = nextThumbnailPlaybackIndex(
                eligible: playableIndices,
                afterIndex: index
            )

        case let .failed(index, identity):
            state.failedPlayerIdentities[index] = identity
            reconcileActive()
        }
    }

    private func isScheduled(_ index: Int) -> Bool {
        mode == .simultaneous || state.sequentialActiveIndex == index
    }

    private func cachePriority(
        for index: Int,
        playable: Set<Int>
    ) -> StoryVideoCachePriority? {
        guard playable.contains(index) else { return nil }
        if mode == .simultaneous { return .eligible }
        guard let activeIndex = state.sequentialActiveIndex else { return nil }
        if index == activeIndex { return .scheduled }
        guard playable.count > 1,
              nextThumbnailPlaybackIndex(eligible: playable, afterIndex: activeIndex) == index
        else { return nil }
        return .lookAhead
    }

    private func demand(
        index: Int,
        priority: StoryVideoCachePriority
    ) -> StoryVideoCacheDemand? {
        guard items.indices.contains(index), let url = URL(string: items[index].url) else {
            return nil
        }
        return StoryVideoCacheDemand(url: url, priority: priority)
    }

    private mutating func restartFromFirst() {
        state.restartGeneration &+= 1
        state.sequentialActiveIndex = mode == .sequential
            ? nextThumbnailPlaybackIndex(eligible: playableIndices, afterIndex: nil)
            : nil
    }

    private mutating func reconcileActive() {
        guard mode == .sequential else {
            state.sequentialActiveIndex = nil
            return
        }
        let playable = playableIndices
        if let current = state.sequentialActiveIndex, playable.contains(current) {
            return
        }
        state.sequentialActiveIndex = nextThumbnailPlaybackIndex(
            eligible: playable,
            afterIndex: state.sequentialActiveIndex
        )
    }
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
