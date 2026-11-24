import AVFoundation
import AVKit
import Foundation
import UIKit
@testable import DigiaEngage

/// Story-video commands: holds, rotation control and the player log. Mirrors
/// the Flutter/Android story drivers.
///
/// The strip's thumbnail videos and the viewer play on real AVPlayers here
/// (only their pixels are frozen for goldens), so the log below samples what
/// the SDK asked them to do the way `InlinePlayerWatch` does for the
/// hand-written tests: every player ever seen, where its playhead was when
/// it started playing, and whether it has left the screen.
let yamlStoryVideoHandlers: [String: YamlHandler] = [
    "hold": holdStory,
    "playThumbnails": playThumbnails,
    "endVideo": endVideo,
    "assertStoryViewer": assertStoryViewer,
    "failVideo": { _, _ in
        throw YamlTestFailure(
            "failVideo is not supported on iOS",
            expected: "a stack with a fault seam for its video player",
            actual: "a real AVPlayer, which cannot be broken mid-play; the open-fail variant covers the skip")
    },
    "stallVideos": { _, _ in
        throw YamlTestFailure(
            "stallVideos is not supported on iOS",
            expected: "a stack with a download gate for its story videos",
            actual: "file-loaded videos, which open with no download to hold")
    },
    "assertVideo": assertVideo,
    "assertMedia": { _, _ in
        throw YamlTestFailure(
            "assertMedia is not supported on iOS",
            expected: "a stack whose story videos download over the network",
            actual: "file-loaded videos, with no download to observe")
    },
    "assertStoryCache": { _, _ in
        throw YamlTestFailure(
            "assertStoryCache is not supported on iOS",
            expected: "a stack whose story videos download over the network",
            actual: "file-loaded videos, with nothing to wait for")
    },
    "mockStoryCache": { _, _ in
        throw YamlTestFailure(
            "mockStoryCache is not supported on iOS",
            expected: "a stack with a download cache to shrink",
            actual: "file-loaded videos, with no download cache to shrink")
    },
    "demandStoryVideos": { _, _ in
        throw YamlTestFailure(
            "demandStoryVideos is not supported on iOS",
            expected: "a stack whose story videos download through a queue",
            actual: "file-loaded videos, with no queue to drive")
    },
    "releaseMedia": { _, _ in
        throw YamlTestFailure(
            "releaseMedia is not supported on iOS",
            expected: "a stack whose story videos download over the network",
            actual: "file-loaded videos, with no download to hold")
    },
    "mockPoster": { _, _ in
        throw YamlTestFailure(
            "mockPoster is not supported on iOS",
            expected: "a stack that cuts posters through a mockable channel",
            actual: "file-loaded videos, with no poster seam to mock")
    },
    "assertPoster": { _, _ in
        throw YamlTestFailure(
            "assertPoster is not supported on iOS",
            expected: "a stack that cuts posters through a mockable channel",
            actual: "file-loaded videos, with no poster seam to observe")
    },
]

/// Every story-video player the running test has seen, sampled from the live
/// view hierarchy. Held strongly: an `ObjectIdentifier` of a released player
/// could be reused by the next one.
final class YamlStoryVideos {
    final class Entry {
        init(_ player: AVPlayer) { self.player = player }
        let player: AVPlayer
        var startMs: Int?
        var everPlayed = false
        var gone = false
        var viewer = false
    }
    var seen: [Entry] = []
}

/// Every canvas-video player the running test has seen. The test runtime
/// (below) makes real players that never load, so play/pause/restart are
/// recorded here for assertVideo/endVideo instead of read off the player.
final class YamlCanvasVideos {
    final class Entry {
        let player: AVPlayer
        var startMs: Int?
        var everPlayed = false
        var playing = false
        var gone = false
        init(_ player: AVPlayer) { self.player = player }
    }
    var seen: [Entry] = []

    /// The test runtime handed to canvas video: real players with the loop,
    /// pause and restart the authored fixture asks of them recorded here.
    /// (The pixels never load in a test, exactly like the harness probe.)
    lazy var runtime: CanvasVideoRuntime = CanvasVideoRuntime(
        makePlayer: { [weak self] item in
            let player = AVPlayer(playerItem: item)
            self?.seen.append(Entry(player))
            return player
        },
        play: { [weak self] player in
            guard let entry = self?.seen.first(where: { $0.player === player }) else { return }
            if entry.startMs == nil { entry.startMs = 0 }
            entry.everPlayed = true
            entry.playing = true
        },
        pause: { [weak self] player in
            self?.seen.first(where: { $0.player === player })?.playing = false
        },
        restart: { [weak self] player in
            guard let entry = self?.seen.first(where: { $0.player === player }) else { return }
            player.seek(to: .zero)
            if entry.startMs == nil { entry.startMs = 0 }
            entry.everPlayed = true
            entry.playing = true
        })
}

/// Merges the canvas video players on screen into the World's canvas log.
/// Canvas video renders in an AVPlayerViewController, not in an inline
/// story container, so the story walk never sees it.
@MainActor func scanCanvasPlayers(_ world: YamlWorld) {
    guard let window = world.window else { return }
    var found: [AVPlayer] = []
    func walk(_ vc: UIViewController?) {
        guard let vc else { return }
        if let playerVC = vc as? AVPlayerViewController, let player = playerVC.player {
            found.append(player)
        }
        for child in vc.children { walk(child) }
        walk(vc.presentedViewController)
    }
    walk(window.rootViewController)
    for entry in world.canvasVideos.seen {
        if !found.contains(where: { $0 === entry.player }) {
            entry.gone = true
        }
    }
}

/// Merges the players on screen into the World's story log.
@MainActor func scanStoryPlayers(_ world: YamlWorld) {
    guard let window = world.window else { return }
    var found: [AVPlayer] = []
    var viewerOf: [ObjectIdentifier: Bool] = [:]
    func walk(_ view: UIView) {
        if let container = view as? InlineStoryPlayerContainer,
           let player = container.playerLayer.player
        {
            found.append(player)
            let frame = container.convert(container.bounds, to: window)
            viewerOf[ObjectIdentifier(player)] =
                frame.width >= window.bounds.width * 0.9
        }
        for subview in view.subviews { walk(subview) }
    }
    walk(window)
    for player in found
        where !world.storyVideos.seen.contains(where: { $0.player === player })
    {
        let entry = YamlStoryVideos.Entry(player)
        entry.viewer = viewerOf[ObjectIdentifier(player)] ?? false
        world.storyVideos.seen.append(entry)
    }
    for entry in world.storyVideos.seen {
        if found.contains(where: { $0 === entry.player }) {
            if entry.player.rate > 0 {
                entry.everPlayed = true
                if entry.startMs == nil {
                    let seconds = entry.player.currentTime().seconds
                    if seconds.isFinite {
                        entry.startMs = Int((seconds * 1000).rounded())
                    }
                }
            }
        } else {
            entry.gone = true
        }
    }
}

/// A finger pressing down at a point on the screen and resting there for the
/// duration, then lifting. A hold is not a tap: letting go never turns the page.
@MainActor private func holdStory(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let window = world.window,
          let point = args["point"] as? String,
          let duration = args["for"] as? YamlDuration
    else {
        throw YamlTestFailure(
            "hold needs point and for",
            expected: #"hold: { point: "x%,y%", for: 5s }"#,
            actual: "\(args)",
            line: world.step.line)
    }
    try TouchSynthesizer.press(
        at: pointOnScreen(point, in: window),
        in: window,
        for: Double(duration.milliseconds) / 1000)
}

/// Story strip thumbnail videos play for real from here on, instead of
/// staying frozen on their placeholder, so a rotation test can end and fail
/// them. Viewer videos always play. Reset by every launch.
@MainActor private func playThumbnails(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    scanStoryPlayers(world)
    InlineStoryRailPlaybackCoordinator.thumbnailPlaybackDisabledForTesting = false
}

/// Every currently-playing story video ends now, as if it ran to its
/// duration: the strip hands over to the next video, a viewer page moves the
/// story on. A step error when no story video is playing.
@MainActor private func endVideo(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    scanStoryPlayers(world)
    scanCanvasPlayers(world)
    // The ready gate below waits for a playing video with a known duration, so
    // a seek lands near its end. Canvas players never load in tests (their
    // durations stay unknown), so a canvas-only end skips the wait: the end
    // notification below drives their loop wiring directly.
    let canvasLive = world.canvasVideos.seen.filter { !$0.gone }
    if world.storyVideos.seen.filter({ !$0.gone && $0.player.rate > 0 }).isEmpty && !canvasLive.isEmpty {
        for entry in canvasLive {
            endCanvasVideo(entry)
        }
        await world.settle()
        return
    }
    // After a foreground return the player rebuffers with no duration yet and
    // seeking it is a no-op (inlineRunOut guards on a numeric duration), so
    // wait for a known duration first.
    let readyDeadline = Date().addingTimeInterval(5)
    var ready = false
    while !ready, Date() <= readyDeadline {
        scanStoryPlayers(world)
        ready = world.storyVideos.seen.contains {
            !$0.gone && $0.player.rate > 0 && ($0.player.currentItem?.duration.isNumeric ?? false)
        }
        if !ready { try? await Task.sleep(nanoseconds: 15_000_000) }
    }
    scanStoryPlayers(world)
    let playing = world.storyVideos.seen.filter { !$0.gone && $0.player.rate > 0 }
    if playing.isEmpty {
        throw YamlTestFailure(
            "no story video playing",
            expected: "a playing story video to end",
            actual: "none",
            line: world.step.line)
    }
    for entry in playing { await inlineRunOut(entry.player) }
    // The seek puts the playhead 150 ms before the end; the inline viewer
    // reports the end only once playback actually gets there, in real time.
    // A looping canvas card restarts instead of ending, as platform looping
    // does; the rest stay ended.
    for entry in world.canvasVideos.seen where !entry.gone && entry.playing {
        endCanvasVideo(entry)
    }
    ComponentTestHost.drainRunLoop(for: 0.45)
    await world.settle()
}

/// Ends one canvas video the way its end-of-item would: a looped card
/// restarts through its observer (as the harness probe's playToEnd does) and
/// stays playing; the rest end here.
@MainActor private func endCanvasVideo(_ entry: YamlCanvasVideos.Entry) {
    entry.playing = false
    if let item = entry.player.currentItem {
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    }
}

/// Whether the full-screen story viewer is open, as distinct from the strip
/// that stays on its slot behind it. The viewer is the view controller
/// presented over the app (an inline viewer is also tracked in the SDK, a
/// canvas viewer only by its presentation). Polls, as presenting and
/// dismissing both animate.
@MainActor private func assertStoryViewer(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let want = args["open"] as? Bool else {
        throw YamlTestFailure(
            "assertStoryViewer needs open",
            expected: "assertStoryViewer: { open: true }",
            actual: "\(args)",
            line: world.step.line)
    }
    let deadline = Date().addingTimeInterval(8)
    var open = presentedStoryViewer(world) != nil
    while open != want, Date() <= deadline {
        try? await Task.sleep(nanoseconds: 15_000_000)
        open = presentedStoryViewer(world) != nil
    }
    if open != want {
        throw YamlTestFailure(
            "the story viewer is \(open ? "open" : "closed")",
            expected: "open: \(want)",
            actual: "open: \(open)",
            line: world.step.line)
    }
}

/// The view controller presented over the app, when the story viewer is up.
@MainActor func presentedStoryViewer(_ world: YamlWorld) -> UIViewController? {
    guard let window = world.window else { return nil }
    var top = window.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top === window.rootViewController ? nil : top
}

/// Where the story viewer lays a control out: the call-to-action sits full
/// width less 24 pt each side, 20 pt above the bottom safe area; the chrome
/// buttons sit in a row of 48 pt targets 8 pt apart, inset by the indicator's
/// horizontal padding, 12 pt under the indicator (position 0 is the close
/// button when it shows, the mute button sits left of it).
@MainActor func storyViewerTapPoint(_ window: UIWindow, label: String?, hasText: Bool) -> CGPoint? {
    guard SDKInstance.shared.controller.activeStoryOverlay != nil else { return nil }
    if hasText {
        return CGPoint(
            x: window.bounds.midX,
            y: window.bounds.height - window.safeAreaInsets.bottom - 20 - 21)
    }
    let position: Int
    switch label {
    case "Close story": position = 0
    case "Mute story", "Unmute story": position = 1
    default: return nil
    }
    guard let overlay = SDKInstance.shared.controller.activeStoryOverlay else { return nil }
    let indicator = overlay.config.indicator
    let x = window.bounds.width - CGFloat(indicator.horizontalPadding) - 24 - CGFloat(position) * (48 + 8)
    let y = window.safeAreaInsets.top + CGFloat(indicator.topPadding + CGFloat(indicator.height)) + 12 + 24
    return CGPoint(x: x, y: y)
}

/// What the test's video stand-ins saw since launch: the ordered list of
/// playhead offsets every player started from, how many started playing and
/// left, how many play now, and whether the story viewer's current video
/// plays muted. Polls until the expectation holds, so a video that starts a
/// beat after the step still counts.
@MainActor private func assertVideo(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    if args.isEmpty {
        throw YamlTestFailure(
            "assertVideo: nothing to check",
            expected: "one of starts, played, released, playing, muted",
            line: world.step.line)
    }
    func snapshot() -> (starts: [Int], played: Int, released: Int, playing: Int, muted: Bool?) {
        scanStoryPlayers(world)
        scanCanvasPlayers(world)
        let seen = world.storyVideos.seen
        let canvas = world.canvasVideos.seen
        let starts = seen.compactMap(\.startMs) + canvas.compactMap(\.startMs)
        let played = seen.filter(\.everPlayed).count + canvas.filter(\.everPlayed).count
        let released = seen.filter(\.gone).count + canvas.filter(\.gone).count
        let playing = seen.filter { !$0.gone && $0.player.rate > 0 }.count
            + canvas.filter { !$0.gone && $0.playing }.count
        let viewer = seen.filter { $0.viewer && !$0.gone }.last.map { $0.player }
            ?? canvas.filter { !$0.gone }.last.map { $0.player }
            ?? seen.filter { !$0.gone }.last.map { $0.player }
        return (starts, played, released, playing, viewer?.isMuted)
    }
    func count(_ snap: (starts: [Int], played: Int, released: Int, playing: Int, muted: Bool?), _ name: String) -> Int {
        switch name {
        case "played": return snap.played
        case "released": return snap.released
        default: return snap.playing
        }
    }
    func holds(_ snap: (starts: [Int], played: Int, released: Int, playing: Int, muted: Bool?)) -> Bool {
        if let want = args["starts"] {
            guard let list = want as? [Any], list.count == snap.starts.count,
                  zip(list, snap.starts).allSatisfy({ matchesVideoValue($0, $1) })
            else { return false }
        }
        for name in ["played", "released", "playing"] {
            if let want = args[name], !matchesVideoValue(want, count(snap, name)) {
                return false
            }
        }
        if let want = args["muted"] as? Bool, snap.muted != want { return false }
        return true
    }
    // Poll: a video the step before started may take a beat to play.
    let deadline = Date().addingTimeInterval(3)
    var snap = snapshot()
    while !holds(snap), Date() <= deadline {
        try? await Task.sleep(nanoseconds: 15_000_000)
        snap = snapshot()
    }
    if holds(snap) { return }
    if let want = args["starts"], !holds(snap) {
            throw YamlTestFailure(
                "story videos started from \(snap.starts)",
                expected: "\(want)",
                actual: "\(snap.starts)",
                line: world.step.line)
        }
        for name in ["played", "released", "playing"] {
            if let want = args[name], !matchesVideoValue(want, count(snap, name)) {
                throw YamlTestFailure(
                    "story videos \(name): \(count(snap, name))",
                    expected: "\(want)",
                    actual: "\(count(snap, name))",
                    line: world.step.line)
            }
        }
        if let want = args["muted"] as? Bool, snap.muted != want {
            throw YamlTestFailure(
                "the story viewer video plays \(snap.muted.map { $0 ? "muted" : "with sound" } ?? "nowhere")",
                expected: "muted: \(want)",
                actual: "muted: \(snap.muted.map(String.init(describing:)) ?? "none")",
                line: world.step.line)
        }
}

/// Whether a produced video value satisfies the YAML expectation: a value
/// matcher map or an exact number.
private func matchesVideoValue(_ want: Any, _ got: Int) -> Bool {
    if let matcher = YamlMatch.valueMatcher(want) {
        return YamlMatch.matchValue(matcher, NSNumber(value: got), present: true)
    }
    if let number = want as? NSNumber { return number.intValue == got }
    return false
}

private func pointOnScreen(_ point: String, in window: UIWindow) throws -> CGPoint {
    guard let match = try NSRegularExpression(pattern: #"^\s*(\d+(?:\.\d+)?)%\s*,\s*(\d+(?:\.\d+)?)%\s*$"#)
        .firstMatch(in: point, range: NSRange(point.startIndex..., in: point)),
        let xRange = Range(match.range(at: 1), in: point),
        let yRange = Range(match.range(at: 2), in: point),
        let x = Double(point[xRange]), let y = Double(point[yRange])
    else {
        throw YamlTestFailure(
            "bad point",
            expected: "\"x%,y%\", e.g. \"50%,90%\"",
            actual: point)
    }
    let size = window.bounds.size
    return CGPoint(x: size.width * x / 100, y: size.height * y / 100)
}
