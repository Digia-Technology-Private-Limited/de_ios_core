import AVFoundation
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

// The real touches, app lifecycle and story players the inline suites in this folder use, on top of
// the touch-free helpers in `Tests/DigiaEngageTests/FixtureBehaviour/InlineBehaviourSupport.swift`.

/// A video player the story rail or viewer put on screen, and where it was first seen playing.
@MainActor
final class InlineSeenPlayer {
    let player: AVPlayer
    /// Index of the rail card it sits on, or nil when it fills the screen (the viewer's).
    let card: Int?
    /// Playhead, in seconds, the first time it was seen playing; nil while it never played.
    var firstPlayingAt: Double?

    init(player: AVPlayer, card: Int?) {
        self.player = player
        self.card = card
    }
}

extension SdkHarness {

    /// Taps the [index]th card of a story rail drawn in [slot], with the rail's card geometry.
    func tapStoryCard(_ index: Int, in slot: InlineSlotFrame, card: StoryCardConfig) async throws {
        let window = try #require(window)
        try await waitUntil("the story rail is laid out") { !slot.frame.isNull && slot.frame.height > 1 }
        // Settle any layout pass the delivery started before measuring.
        TouchSynthesizer.drainRunLoop(for: 0.3)
        let width = CGFloat(card.width)
        let spacing = CGFloat(card.spacing)
        let x = slot.frame.minX + spacing + CGFloat(index) * (width + spacing) + width / 2
        try TouchSynthesizer.tap(at: CGPoint(x: x, y: slot.frame.midY), in: window)
    }

    /// A real touch on the story viewer's call-to-action button, once it reads [label].
    ///
    /// The viewer's page reads out as one accessibility node holding every label on it, so its
    /// controls have no frame of their own to tap; the touch goes where `InlineStoryOverlayContent`
    /// lays the button out: full width less 24 pt each side, 20 pt above the bottom safe area,
    /// 12 pt of padding around a 16 pt line.
    func tapStoryCTA(_ label: String) async throws {
        let window = try #require(window)
        try await waitUntil("the call to action \(label) is on screen") { self.isShowing(label) }
        let center = window.bounds.height - window.safeAreaInsets.bottom - 20 - 21
        try TouchSynthesizer.tap(at: CGPoint(x: window.bounds.midX, y: center), in: window)
    }

    /// A real touch on the story viewer's [position]th round button from the right (0 is the
    /// close button when it shows, the mute button sits left of it), once it reads [label]. As
    /// for `tapStoryCTA`, the touch goes where the viewer lays the buttons out: a row of 48 pt
    /// targets 8 pt apart, inset by the indicator's horizontal padding, 12 pt under the indicator.
    func tapStoryButton(_ label: String, position: Int, indicator: StoryIndicatorDisplayConfig) async throws {
        let window = try #require(window)
        try await waitUntil("the \(label) button is on screen") { self.isShowing(label) }
        let x = window.bounds.width - CGFloat(indicator.horizontalPadding) - 24 - CGFloat(position) * (48 + 8)
        let y = window.safeAreaInsets.top + CGFloat(indicator.topPadding + indicator.height) + 12 + 24
        try TouchSynthesizer.tap(at: CGPoint(x: x, y: y), in: window)
    }

    /// Whether the full-screen story viewer is up: the SDK holds an open story and the viewer is
    /// presented over the app.
    var storyViewerIsOpen: Bool {
        sdk.controller.activeStoryOverlay != nil && presentedViewer != nil
    }

    /// Waits for the story viewer to be presented and its cross-dissolve to finish, so a touch
    /// reaches it rather than the page under it.
    func waitForStoryViewer() async throws {
        try await waitUntil("the story viewer is presented") { self.storyViewerIsOpen }
        try await waitUntil("the story viewer is in place") {
            guard let presented = self.presentedViewer else { return false }
            return !presented.isBeingPresented && presented.view.window != nil
        }
        TouchSynthesizer.drainRunLoop(for: 0.4)
    }

    /// Waits for the story viewer to be gone, from the SDK and from the screen.
    func waitForStoryViewerClosed(timeout: TimeInterval = 3) async throws {
        try await waitUntil("the story viewer is closed", timeout: timeout) {
            self.sdk.controller.activeStoryOverlay == nil && self.presentedViewer == nil
        }
    }

    /// Closes the story viewer if it is up, waits for it to leave the screen, and sends what it
    /// reported on the way out. Call at the end of a test that opened it: a viewer torn down with
    /// the window reports its dismissal late, into the next test's backend.
    func closeStoryViewer() async throws {
        if sdk.controller.activeStoryOverlay != nil { sdk.controller.dismissStoryOverlay() }
        try await waitForStoryViewerClosed()
        TouchSynthesizer.drainRunLoop(for: 0.3)
        _ = try await events()
    }

    /// A real tap on the story viewer: [fraction] of the way across the screen, at its middle.
    func tapStoryViewer(atFraction fraction: CGFloat) throws {
        let window = try #require(window)
        let point = CGPoint(x: window.bounds.width * fraction, y: window.bounds.midY)
        try TouchSynthesizer.tap(at: point, in: window)
    }

    /// The video players on screen now: each `InlineStoryPlayerContainer` holding a player, with
    /// the rail card it sits on (by its frame inside [slot]).
    func storyPlayers(in slot: InlineSlotFrame, card: StoryCardConfig) -> [(card: Int?, player: AVPlayer)] {
        guard let window else { return [] }
        var found: [(Int?, AVPlayer)] = []
        func walk(_ view: UIView) {
            if let container = view as? InlineStoryPlayerContainer, let player = container.playerLayer.player {
                let frame = container.convert(container.bounds, to: window)
                let stride = CGFloat(card.width + Double(card.spacing))
                let index = frame.width < window.bounds.width * 0.9
                    ? Int(((frame.midX - slot.frame.minX - CGFloat(card.spacing)) / stride).rounded(.down))
                    : nil
                found.append((index, player))
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(window)
        return found
    }
}

/// Watches the story players for as long as a test runs, keeping every player it saw in the order
/// it first saw each, with where its playhead was when it started playing.
///
/// Players are held strongly: an `ObjectIdentifier` of a released player could otherwise be
/// reused by the next one.
@MainActor
final class InlinePlayerWatch {
    private(set) var seen: [InlineSeenPlayer] = []
    private var task: Task<Void, Never>?

    init(_ sdk: SdkHarness, slot: InlineSlotFrame, card: StoryCardConfig) {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample(sdk.storyPlayers(in: slot, card: card))
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    deinit { task?.cancel() }

    func stop() { task?.cancel() }

    private func sample(_ players: [(card: Int?, player: AVPlayer)]) {
        for (card, player) in players {
            let entry: InlineSeenPlayer
            if let known = seen.first(where: { $0.player === player }) {
                entry = known
            } else {
                entry = InlineSeenPlayer(player: player, card: card)
                seen.append(entry)
            }
            if entry.firstPlayingAt == nil, player.rate > 0 {
                entry.firstPlayingAt = player.currentTime().seconds
            }
        }
    }

    /// The players that have started playing, in order.
    var played: [InlineSeenPlayer] { seen.filter { $0.firstPlayingAt != nil } }

    /// The [count]th player to start playing, once it has.
    func playing(_ count: Int) -> InlineSeenPlayer? {
        let played = played
        return played.count >= count ? played[count - 1] : nil
    }

    /// Each player that played, as "card <n> from <s>s": the card it sits on and where it started,
    /// read as 0 s when it began within half a second of the start and as 2 s when it began
    /// between 1.9 s and 2.6 s (anything else reads -1 s).
    var starts: [String] {
        played.map { entry in
            let start = entry.firstPlayingAt ?? -1
            let whole = start < 0.5 ? 0 : (start >= 1.9 && start < 2.6 ? 2 : -1)
            return "card \(entry.card.map(String.init) ?? "full") from \(whole)s"
        }
    }
}

/// Moves a player's playhead to just before the end of its video, so it runs out the way it would
/// after playing through (the Flutter tests move the fake player's playhead the same way).
@MainActor
func inlineRunOut(_ player: AVPlayer) async {
    guard let duration = player.currentItem?.duration, duration.isNumeric else { return }
    let target = CMTimeSubtract(duration, CMTime(value: 150, timescale: 1_000))
    await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
}

/// The app going to the background and coming back, as UIKit announces it to the SDK.
@MainActor
enum InlineAppLifecycle {
    static func resignActive() {
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: UIApplication.shared)
        TouchSynthesizer.drainRunLoop(for: 0.1)
    }

    static func becomeActive() {
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        TouchSynthesizer.drainRunLoop(for: 0.1)
    }
}
