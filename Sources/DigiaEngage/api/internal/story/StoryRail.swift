import AVFoundation
import SwiftUI
import UIKit
internal import DigiaVideoEngine

// The one story rail (T8): the inline story and the canvas story rail draw this view. It owns the
// visibility rule and the take-turns schedule; each `StoryThumbnail` only obeys play/pause.
// Mirrors Android `StoryRail`.

// Wait until most of a card is visible before starting it.
let storyRailStartWhenVisible = 0.75

// Once started, keep playing until the card is mostly off-screen.
let storyRailStopBelow = 0.25

/// The key a rail card and a viewer page borrow their pool player under: namespaced by the
/// campaign that owns the story, so two stories on screen from different campaigns never share a
/// holder. A blank namespace keeps the bare `story-<index>` form. Mirrors Android `storyPoolKey`.
func storyPoolKey(namespace: String?, index: Int) -> String {
    guard let namespace, !namespace.trimmingCharacters(in: .whitespaces).isEmpty else {
        return "story-\(index)"
    }
    return "\(namespace)/story-\(index)"
}

/// What the rail decided for one card. A lone video loops its window in place; a rotation hands over instead.
struct StoryRailDecision: Equatable {
    let play: Bool
    let repeatWindow: Bool
}

/// The rail's visibility, lifecycle, failure, restart and turn state. Pure, so the schedule is
/// tested without a view. The cards take turns, one at a time (continuous is the only mode, OD-24: a
/// campaign that still sends `thumbnailVideoPlayback: "simultaneous"` plays the same way; the field
/// is no longer parsed). Mirrors Android `StoryRailState`.
struct StoryRailState: Equatable {
    var lifecycleActive = false
    var overlayVisible = false
    var slotVisible = false
    var eligible: Set<Int> = []
    /// Cards whose video really failed: out of the rotation for the rest of the session.
    var failed: Set<Int> = []
    /// Cards the pool refused or evicted since the rotation last restarted or a turn last played.
    /// They stay in the rotation (`playable`) but sit out `turnCandidates`, so a pool that keeps
    /// refusing waits for the next restart instead of being retried every frame.
    var skipped: Set<Int> = []
    var activeIndex: Int? = nil
    var restartGeneration = 0

    var playable: Set<Int> { eligible.subtracting(failed) }

    private var turnCandidates: Set<Int> { playable.subtracting(skipped) }

    /// A settled scroll: cards already in stay until they drop below the exit threshold, new ones
    /// join above the entry threshold, and the playing card keeps its turn while it is still in
    /// view; otherwise the turn moves to the next eligible card (as Flutter).
    func visibilityChanged(items: [StoryItemConfig], visibility: StoryRailVisibility) -> StoryRailState {
        var updated = self
        updated.slotVisible = visibility.slotVisible
        updated.eligible = updateStoryRailEligibility(
            current: eligible,
            slotVisible: visibility.slotVisible,
            visibleFractions: visibility.cardFractions,
            items: items
        )
        return updated.reconcileActive()
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

    /// The card's video really failed: it leaves the rotation for the session.
    func fail(index: Int) -> StoryRailState {
        var updated = self
        updated.failed.insert(index)
        return updated.reconcileActive()
    }

    /// A turn that played: the next card is up, and any card the pool refused earlier is tried
    /// again on its next turn.
    func complete(index: Int) -> StoryRailState {
        guard activeIndex == index else { return self }
        var updated = self
        updated.skipped = []
        updated.activeIndex = nextStoryRailIndex(eligible: playable, afterIndex: index)
        return updated
    }

    /// The pool refused or evicted this card's player. That says nothing about its video, so it
    /// keeps its place in the rotation (unlike `fail`) and only loses this turn. Once every
    /// playable card has been refused with no turn in between, nothing is scheduled until the
    /// next restart.
    func skip(index: Int) -> StoryRailState {
        guard activeIndex == index else { return self }
        var updated = self
        updated.skipped.insert(index)
        updated.activeIndex = nextStoryRailIndex(eligible: updated.turnCandidates, afterIndex: index)
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
        updated.skipped = []
        updated.activeIndex = nextStoryRailIndex(eligible: updated.playable, afterIndex: nil)
        updated.restartGeneration &+= 1
        return updated
    }

    private func reconcileActive() -> StoryRailState {
        if let current = activeIndex, playable.contains(current) { return self }
        var updated = self
        updated.activeIndex = nextStoryRailIndex(eligible: turnCandidates, afterIndex: activeIndex)
        return updated
    }
}

struct StoryRailVisibility: Equatable {
    let slotVisible: Bool
    let cardFractions: [Int: Double]
}

func storyRailVisibility(rail: CGRect?, cards: [Int: CGRect], viewport: CGRect) -> StoryRailVisibility {
    guard let rail, !rail.isNull, !rail.isEmpty, !viewport.isNull, !viewport.isEmpty else {
        return StoryRailVisibility(slotVisible: false, cardFractions: [:])
    }
    let visibleRail = rail.intersection(viewport)
    let slotVisible = !visibleRail.isNull && !visibleRail.isEmpty
    var fractions: [Int: Double] = [:]
    for (index, card) in cards where !card.isNull && !card.isEmpty {
        let visible = card.intersection(rail).intersection(viewport)
        let totalArea = card.width * card.height
        let visibleArea = visible.isNull || visible.isEmpty ? 0 : visible.width * visible.height
        fractions[index] = totalArea > 0 ? min(max(Double(visibleArea / totalArea), 0), 1) : 0
    }
    return StoryRailVisibility(slotVisible: slotVisible, cardFractions: fractions)
}

func updateStoryRailEligibility(
    current: Set<Int>,
    slotVisible: Bool = true,
    visibleFractions: [Int: Double],
    items: [StoryItemConfig],
    startWhenVisible: Double = storyRailStartWhenVisible,
    stopWhenBelow: Double = storyRailStopBelow
) -> Set<Int> {
    assert(startWhenVisible > stopWhenBelow)
    guard slotVisible else { return current }
    var next = current.filter { index in
        guard items.indices.contains(index) else { return false }
        let item = items[index]
        return item.type == .video && (visibleFractions[index] ?? 0) >= stopWhenBelow
    }
    for (index, rawFraction) in visibleFractions {
        guard items.indices.contains(index) else { continue }
        let item = items[index]
        guard item.type == .video else { continue }
        if min(max(rawFraction, 0), 1) >= startWhenVisible { next.insert(index) }
    }
    return next
}

func nextStoryRailIndex(eligible: Set<Int>, afterIndex: Int?) -> Int? {
    let ordered = eligible.sorted()
    guard let first = ordered.first else { return nil }
    guard let afterIndex else { return first }
    return ordered.first(where: { $0 > afterIndex }) ?? first
}

// MARK: - Handover

/// The handover a tap on a rail card starts (the engine's `storyRailHandover`): only a video card
/// that is playing and holds its player hands it over; any other tap opens the viewer fresh.
@MainActor
func storyRailHandover(item: StoryItemConfig, playing: Bool, key: String, pool: VideoPlayerPool) -> StoryHandover? {
    storyRailHandover(
        url: item.type == .video ? mediaUsableURL(item.url) : nil, playing: playing, key: key, pool: pool)
}

// MARK: - The rail view

private let storyRailCoordinateSpace = "DigiaStoryRail"

struct StoryRailGeometry: Equatable {
    var rail: CGRect?
    var cards: [Int: CGRect] = [:]
}

struct StoryRailGeometryPreference: PreferenceKey {
    static let defaultValue = StoryRailGeometry()

    static func reduce(value: inout StoryRailGeometry, nextValue: () -> StoryRailGeometry) {
        let next = nextValue()
        if let rail = next.rail { value.rail = rail }
        value.cards.merge(next.cards) { _, new in new }
    }
}

/// The rail of tappable story cards. Tapping a playing video hands its player to the viewer
/// (`StoryHandover`); a tap on a still opens with no handover.
@MainActor
struct StoryRail: View {
    let items: [StoryItemConfig]
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let cardCornerRadius: CGFloat
    let cardSpacing: CGFloat
    let overlayOpen: Bool
    let onOpen: @MainActor (Int, StoryHandover?) -> Void

    @State private var playback: StoryRailState
    @State private var latestGeometry = StoryRailGeometry()
    @State private var viewportBounds = CGRect.null
    @State private var scrollSettleTask: Task<Void, Never>?
    @State private var lastSettledVisibility: StoryRailVisibility?
    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.mediaServices) private var services

    init(
        items: [StoryItemConfig],
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        cardCornerRadius: CGFloat,
        cardSpacing: CGFloat,
        overlayOpen: Bool,
        onOpen: @escaping @MainActor (Int, StoryHandover?) -> Void
    ) {
        self.items = items
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.cardCornerRadius = cardCornerRadius
        self.cardSpacing = cardSpacing
        self.overlayOpen = overlayOpen
        self.onOpen = onOpen
        _playback = State(initialValue: StoryRailState())
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    card(index: index, item: item)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: StoryRailGeometryPreference.self,
                                    value: StoryRailGeometry(cards: [
                                        index: proxy.frame(in: .named(storyRailCoordinateSpace))
                                    ])
                                )
                            }
                        }
                }
            }
            .padding(.horizontal, cardSpacing)
        }
        .coordinateSpace(name: storyRailCoordinateSpace)
        .background {
            ZStack {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: StoryRailGeometryPreference.self,
                        value: StoryRailGeometry(rail: CGRect(origin: .zero, size: proxy.size))
                    )
                }
                StoryViewportReader { viewport in
                    guard viewportBounds != viewport else { return }
                    viewportBounds = viewport
                    scheduleSettle(latestGeometry)
                }
            }
        }
        .onPreferenceChange(StoryRailGeometryPreference.self) { geometry in
            latestGeometry = geometry
            scheduleSettle(geometry)
        }
        .onAppear {
            playback = playback
                .overlayChanged(visible: overlayOpen)
                .lifecycleChanged(active: UIApplication.shared.applicationState == .active)
            Task { @MainActor in
                await Task.yield()
                settle(latestGeometry)
            }
        }
        .onDisappear {
            scrollSettleTask?.cancel()
            scrollSettleTask = nil
        }
        .onChange(of: StoryRailConfigurationIdentity(items: items)) { _ in
            // New stories: a fresh schedule, keeping only what the host reports.
            var fresh = StoryRailState()
            fresh.lifecycleActive = playback.lifecycleActive
            fresh.overlayVisible = playback.overlayVisible
            fresh.restartGeneration = playback.restartGeneration &+ 1
            playback = fresh
            lastSettledVisibility = nil
            scheduleSettle(latestGeometry)
        }
        .onChange(of: overlayOpen) { playback = playback.overlayChanged(visible: $0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            playback = playback.lifecycleChanged(active: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            playback = playback.lifecycleChanged(active: false)
        }
        .frame(height: cardHeight)
    }

    private func card(index: Int, item: StoryItemConfig) -> some View {
        let decision = playback.decision(index: index)
        let key = storyPoolKey(namespace: campaignKey, index: index)
        return StoryThumbnail(
            item: item,
            poolKey: key,
            playing: decision.play,
            repeatWindow: decision.repeatWindow,
            restartGeneration: playback.restartGeneration,
            onWindowCompleted: { playback = playback.complete(index: index) },
            onFailed: { playback = playback.fail(index: index) },
            onSkipped: { playback = playback.skip(index: index) }
        )
        .frame(width: cardWidth, height: cardHeight)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            let handover = storyRailHandover(
                item: item, playing: decision.play, key: key, pool: services.videoPool)
            onOpen(index, handover)
        }
    }

    private func settle(_ geometry: StoryRailGeometry) {
        guard let rail = geometry.rail, !rail.isNull, !rail.isEmpty, !geometry.cards.isEmpty,
              !viewportBounds.isNull, !viewportBounds.isEmpty else { return }
        let visibility = storyRailVisibility(rail: rail, cards: geometry.cards, viewport: viewportBounds)
        guard visibility.isMateriallyDifferent(from: lastSettledVisibility, retaining: playback.eligible) else { return }
        lastSettledVisibility = visibility
        playback = playback.visibilityChanged(items: items, visibility: visibility)
    }

    private func scheduleSettle(_ geometry: StoryRailGeometry) {
        scrollSettleTask?.cancel()
        scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            settle(geometry)
        }
    }
}

private struct StoryRailConfigurationIdentity: Equatable {
    let items: [StoryItemConfig]
}

private extension StoryRailVisibility {
    func isMateriallyDifferent(from previous: StoryRailVisibility?, retaining eligibleIndices: Set<Int>) -> Bool {
        guard let previous else { return true }
        guard slotVisible == previous.slotVisible else { return true }
        let indices = Set(cardFractions.keys).union(previous.cardFractions.keys)
        let changed = indices.filter { index in
            abs((cardFractions[index] ?? 0) - (previous.cardFractions[index] ?? 0)) > 0.01
        }
        guard !changed.isEmpty else { return false }
        // A passive SwiftUI preference pass may briefly omit an eligible card.
        // Ignore that pass unless another measured card actually moved.
        return !changed.allSatisfy { index in eligibleIndices.contains(index) && cardFractions[index] == nil }
    }
}

private struct StoryViewportReader: UIViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeUIView(context _: Context) -> StoryViewportUIView {
        let view = StoryViewportUIView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: StoryViewportUIView, context _: Context) {
        view.onChange = onChange
        view.reportViewportIfNeeded()
    }
}

private final class StoryViewportUIView: UIView {
    var onChange: ((CGRect) -> Void)?
    private var lastViewport = CGRect.null
    private var scrollObservations: [NSKeyValueObservation] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        observeAncestorScrollViews()
        reportViewportIfNeeded()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        observeAncestorScrollViews()
        reportViewportIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportViewportIfNeeded()
    }

    func reportViewportIfNeeded() {
        guard let window else {
            report(.null)
            return
        }
        var visibleInWindow = convert(bounds, to: window).intersection(window.bounds)
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds {
                visibleInWindow = visibleInWindow.intersection(view.convert(view.bounds, to: window))
            }
            ancestor = view.superview
        }
        let next = visibleInWindow.isNull || visibleInWindow.isEmpty ? CGRect.null : convert(visibleInWindow, from: window)
        report(next)
    }

    private func observeAncestorScrollViews() {
        scrollObservations.removeAll()
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                scrollObservations.append(
                    scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor in self?.reportViewportIfNeeded() }
                    }
                )
            }
            ancestor = view.superview
        }
    }

    private func report(_ next: CGRect) {
        guard !viewport(next, isApproximatelyEqualTo: lastViewport) else { return }
        lastViewport = next
        DispatchQueue.main.async { [weak self] in self?.onChange?(next) }
    }

    private func viewport(_ lhs: CGRect, isApproximatelyEqualTo rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        if lhs.isNull || rhs.isNull { return lhs.isNull && rhs.isNull }
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
