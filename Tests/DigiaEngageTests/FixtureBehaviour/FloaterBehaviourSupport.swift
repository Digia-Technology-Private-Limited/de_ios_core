import AVFoundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// What the PiP and story-floater behaviour suites share on top of `SdkHarness`: delivering a
/// floater over a plain app screen, waiting for its window to be drawn, finding its chrome, and
/// timing it on the wall clock.
///
/// The floater chrome's glyph buttons carry no accessibility label, so a control is found by where
/// it sits — the PiP's chrome corners are fixed by design (`floater_overlay_view.swift`,
/// `collapsedChrome` / `expandedChrome`). Accessibility only locates it; the taps themselves are
/// the sample app's (`FloaterBehaviourTouch.swift`).
///
/// Compiled into both test targets, as `SdkHarness.swift` is.
extension SdkHarness {

    var pip: FloaterOrchestrator { sdk.floaterOrchestrator }
    var storyFloater: FloaterStoryOrchestrator { sdk.floaterStoryOrchestrator }

    /// Mounts the app, reports [screen] (if any) and delivers [key], as a CEP does.
    @discardableResult
    func deliverFloater(
        _ key: String, screen: String? = nil, variables: [String: String]? = nil
    ) throws -> CampaignPresentation {
        try mount { Text("App home") }
        // The floaters read the screen box and insets from the app's window; the package bundle has
        // none, so they are given the mounted window's and the golden device's insets.
        if window.windowScene == nil {
            let insets = ViewImageConfig.engageGolden.safeArea
            activeFloaterWindowGeometryOverride = (
                window.bounds,
                EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
            )
            tearDownHooks.append { activeFloaterWindowGeometryOverride = nil }
        }
        if let screen { setCurrentScreen(screen) }
        return try deliver(key, variables: variables)
    }

    /// Waits until the PiP's media loaded and its window was drawn, then for its entry animation.
    /// Returns when the drawn window was first seen: its timeout started at or before then.
    @discardableResult
    func waitForPipWindow() async throws -> Date {
        try await waitUntil("the PiP window is drawn", timeout: 10) {
            self.pip.isShowing && !self.pip.awaitingMedia && self.pip.activeRect != nil
        }
        let drawnAt = Date()
        try await settle(0.6)
        return drawnAt
    }

    /// Waits until the story floater's window was drawn, then for its entry animation. Returns
    /// when the drawn window was first seen: its timeout started at or before then.
    @discardableResult
    func waitForStoryWindow() async throws -> Date {
        try await waitUntil("the story floater window is drawn", timeout: 6) {
            self.storyFloater.isShowing && self.storyFloater.activeRect != nil
        }
        let drawnAt = Date()
        try await settle(0.8)
        return drawnAt
    }

    /// The PiP window's rect in window points (`activeRect` is `.global`, and the window sits at
    /// the screen's origin).
    func pipRect() throws -> CGRect {
        try #require(pip.activeRect, "No PiP window on screen")
    }

    /// Centres of the on-screen accessibility buttons inside [area], left to right.
    func floaterButtons(in area: CGRect) throws -> [CGPoint] {
        let window = try #require(window)
        ComponentTestHost.enableAccessibilityAutomation()
        var frames: [CGRect] = []
        Self.collectFloaterButtons(in: window, depth: 0, into: &frames)
        var seen = Set<String>()
        return frames
            .filter { !$0.isEmpty && area.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            .filter { seen.insert("\(Int($0.midX)),\(Int($0.midY))").inserted }
            .sorted { $0.minX < $1.minX }
            .map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// The button inside [rect] nearest its [corner] (e.g. `CGPoint(x: rect.maxX, y: rect.minY)`).
    func floaterButton(in rect: CGRect, nearest corner: CGPoint) throws -> CGPoint {
        let buttons = try floaterButtons(in: rect)
        return try #require(
            buttons.min { hypot($0.x - corner.x, $0.y - corner.y) < hypot($1.x - corner.x, $1.y - corner.y) },
            "No chrome button in \(rect)")
    }

    /// The collapsed PiP's ×: its top-right control.
    func pipCloseButton() throws -> CGPoint {
        let rect = try pipRect()
        return try floaterButton(in: rect, nearest: CGPoint(x: rect.maxX, y: rect.minY))
    }

    /// The expanded PiP's top chrome row, left to right.
    func expandedPipTopRow() throws -> [CGPoint] {
        let window = try #require(window)
        return try floaterButtons(in: CGRect(x: 0, y: 0, width: window.bounds.width, height: 200))
    }

    /// Every accessibility label at or under the canvas element authored with [id] — an SF Symbol
    /// glyph reads out its meaning ("Mute", "Volume High").
    func floaterLabels(underId id: String) -> [String] {
        guard let root = element(id: id) else { return [] }
        var labels: [String] = []
        func walk(_ object: NSObject, _ depth: Int) {
            guard depth < 12 else { return }
            if let label = object.accessibilityLabel, !label.isEmpty { labels.append(label) }
            if let view = object as? UIView { view.subviews.forEach { walk($0, depth + 1) } }
            (object.accessibilityElements as? [NSObject])?.forEach { walk($0, depth + 1) }
        }
        walk(root, 0)
        return labels
    }

    /// Every video player drawn in the window, by the file name of what it plays.
    func floaterPlayers(playing fileName: String) -> [AVPlayer] {
        guard let window else { return [] }
        var players: [AVPlayer] = []
        Self.collectPlayers(in: window.layer, into: &players)
        return players.filter {
            ($0.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent == fileName
        }
    }

    private static func collectPlayers(in layer: CALayer, into players: inout [AVPlayer]) {
        if let playerLayer = layer as? AVPlayerLayer, let player = playerLayer.player,
           !players.contains(where: { $0 === player }) {
            players.append(player)
        }
        layer.sublayers?.forEach { collectPlayers(in: $0, into: &players) }
    }

    private static func collectFloaterButtons(in element: NSObject, depth: Int, into frames: inout [CGRect]) {
        guard depth < 60 else { return }
        if let view = element as? UIView, view.isHidden || view.alpha < 0.01 { return }
        if element.accessibilityTraits.contains(.button) { frames.append(element.accessibilityFrame) }
        if let view = element as? UIView {
            view.subviews.forEach { collectFloaterButtons(in: $0, depth: depth + 1, into: &frames) }
        }
        (element.accessibilityElements as? [NSObject])?.forEach {
            collectFloaterButtons(in: $0, depth: depth + 1, into: &frames)
        }
    }
}

/// A shared fixture with each `(path, value)` written into its `templateConfig`, e.g.
/// `(["behavior", "autoDismissAfterMs"], 86_400_000)` to hold a timeout a test is not about.
func floaterFixture(_ path: String, setting overrides: [([String], Any)] = []) throws -> [String: Any] {
    var json = try fixture(path)
    var template = try #require(json["templateConfig"] as? [String: Any])
    for (keys, value) in overrides { template = floaterSet(template, keys[...], value) }
    json["templateConfig"] = template
    return json
}

private func floaterSet(_ object: [String: Any], _ keys: ArraySlice<String>, _ value: Any) -> [String: Any] {
    guard let key = keys.first else { return object }
    var copy = object
    copy[key] = keys.count == 1 ? value : floaterSet(object[key] as? [String: Any] ?? [:], keys.dropFirst(), value)
    return copy
}

/// A Test Kit asset as the fixtures' `{{TESTKIT_ASSET_ORIGIN}}` resolves it: a file URL.
func floaterTestkitAsset(_ name: String) -> String {
    FixtureLoader.resolveAssetOrigin(
        in: "{{TESTKIT_ASSET_ORIGIN}}/assets/\(name)", workspaceUrl: FixtureLoader.workspaceURL())
}

/// Seconds since [start], for wall-clock timing checks.
func floaterElapsed(since start: Date) -> TimeInterval {
    Date().timeIntervalSince(start)
}
