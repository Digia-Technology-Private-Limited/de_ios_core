import Foundation

// Wait until most of a card is visible before starting it.
let storyRailStartWhenVisible = 0.75

// Once started, keep playing until the card is mostly off-screen.
let storyRailStopBelow = 0.25

/// The key a rail thumbnail borrows its pool player under; the viewer reuses it on handover.
/// Namespaced by the campaign that owns the story, so two simultaneously visible stories from
/// different campaigns never share a holder. A null namespace keeps the bare `story-<index>`
/// form. Mirrors Android `storyPoolKey`.
func storyPoolKey(namespace: String?, index: Int) -> String {
    guard let namespace, !namespace.trimmingCharacters(in: .whitespaces).isEmpty else {
        return "story-\(index)"
    }
    return "\(namespace)/story-\(index)"
}

/// What the rail decided for one card: play or pause only. A lone video loops its window in
/// place; a rotation hands over instead. Mirrors Android `StoryRailDecision`.
struct StoryRailDecision: Equatable {
    let play: Bool
    let repeatWindow: Bool
}

/// Owns the rail's visibility, suspension, failure, restart, and take-turns scheduling state.
/// One video plays at a time. There is deliberately no playback-mode field: a received
/// `simultaneous` thumbnail mode is parsed (wire compat) but read as sequential (D7), so the
/// rail stays smooth on all phones. Mirrors Android `StoryRailState`.
///
/// `settled` in `visibilityChanged` matches the view's debounced settle pass: a settle
/// recomputes eligibility from the visible fractions alone, then restarts the rotation from
/// the first eligible card; a live (unsettled) pass keeps hysteresis for cards already in.
struct StoryRailState: Equatable {
    var lifecycleActive = false
    var overlayVisible = false
    var slotVisible = false
    var eligible: Set<Int> = []
    var failed: Set<Int> = []
    var activeIndex: Int? = nil
    var restartGeneration = 0

    var playable: Set<Int> { eligible.subtracting(failed) }

    func visibilityChanged(
        items: [StoryItemConfig],
        slotVisible: Bool,
        visibleFractions: [Int: Double],
        settled: Bool
    ) -> StoryRailState {
        let nextEligible = updateStoryRailEligibility(
            current: settled ? [] : eligible,
            slotVisible: slotVisible,
            visibleFractions: visibleFractions,
            items: items
        )
        var updated = self
        updated.slotVisible = slotVisible
        updated.eligible = nextEligible
        return updated.restartFromFirst()
    }

    func lifecycleChanged(active: Bool) -> StoryRailState {
        if lifecycleActive == active { return self }
        var updated = self
        updated.lifecycleActive = active
        return active ? updated.restartFromFirst() : updated
    }

    func overlayChanged(visible: Bool) -> StoryRailState {
        if overlayVisible == visible { return self }
        var updated = self
        updated.overlayVisible = visible
        return visible ? updated : updated.restartFromFirst()
    }

    func fail(index: Int) -> StoryRailState {
        var updated = self
        updated.failed.insert(index)
        return updated.reconcileActive()
    }

    func complete(index: Int) -> StoryRailState {
        if activeIndex != index { return self }
        var updated = self
        updated.activeIndex = nextStoryRailIndex(eligible: playable, afterIndex: index)
        return updated
    }

    func decision(index: Int) -> StoryRailDecision {
        let scheduled = playable.contains(index) && activeIndex == index
        return StoryRailDecision(
            play: scheduled && lifecycleActive && !overlayVisible && slotVisible,
            repeatWindow: playable.count == 1
        )
    }

    private func restartFromFirst() -> StoryRailState {
        var updated = self
        updated.activeIndex = nextStoryRailIndex(eligible: updated.playable, afterIndex: nil)
        updated.restartGeneration &+= 1
        return updated
    }

    private func reconcileActive() -> StoryRailState {
        var updated = self
        if let current = activeIndex, playable.contains(current) {
            return updated
        }
        updated.activeIndex = nextStoryRailIndex(eligible: playable, afterIndex: activeIndex)
        return updated
    }
}

func updateStoryRailEligibility(
    current: Set<Int>,
    slotVisible: Bool = true,
    visibleFractions: [Int: Double],
    items: [StoryItemConfig],
    startWhenVisible: Double = storyRailStartWhenVisible,
    stopWhenBelow: Double = storyRailStopBelow
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
        if min(max(rawFraction, 0), 1) >= startWhenVisible {
            next.insert(index)
        }
    }
    return next
}

func nextStoryRailIndex(eligible: Set<Int>, afterIndex: Int?) -> Int? {
    let ordered = eligible.sorted()
    guard let first = ordered.first else { return nil }
    guard let afterIndex else { return first }
    return ordered.first(where: { $0 > afterIndex }) ?? first
}
