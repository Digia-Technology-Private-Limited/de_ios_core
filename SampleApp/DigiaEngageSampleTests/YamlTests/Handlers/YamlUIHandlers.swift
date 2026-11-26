import Foundation
import Lottie
import SDWebImage
import SnapshotTesting
import Testing
import UIKit
@testable import DigiaEngage

/// Interacting with what the real `DigiaHost` shows, and snapshots of it.
/// Mirrors `handlers/ui.dart`.
let yamlUiHandlers: [String: YamlHandler] = [
    "tapOn": tapOn,
    "doubleTapOn": doubleTapOn,
    "tapOutside": tapOutside,
    "tapCloseButton": tapCloseButton,
    "tapFloating": tapFloating,
    "dragFloating": dragFloating,
    "assertPipMuted": assertPipMuted,
    "swipe": swipe,
    "inputText": inputText,
    "pickDate": pickDate,
    "assertDatePicker": assertDatePicker,
    "back": unsupported(
        "iOS has no system back gesture: an iOS nudge never closes from back. " +
        "A file that needs it is iOS-specific by platform design."),
    "dismissStoryViewer": dismissStoryViewer,
    "assertGolden": assertGolden,
    "waitForAnimationToEnd": { world, _ in
        await world.settle()
        ComponentTestHost.drainRunLoop(for: 0.03)
    },
    "takeScreenshot": takeScreenshot,
]

@MainActor private func tapOn(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let id = args["id"] as? String
    let text = args["text"] as? String
    let label = args["label"] as? String
    let point = args["point"] as? String
    let exact = args["exact"] as? Bool ?? false
    if [id, text, label, point].compactMap({ $0 }).count != 1 {
        throw YamlTestFailure(
            "needs exactly one of id, text, label, point",
            expected: #"tapOn: { id: ... } | { text: ... } | { label: ... } | { point: "x%,y%" }"#,
            actual: "\(args)")
    }
    if exact && text == nil && label == nil {
        throw YamlTestFailure("exact goes with text or label", actual: "\(args)", line: world.step.line)
    }
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    // A real touch the way a finger does it: `TouchSynthesizer` hands UIKit
    // a digitizer event, and UIKit hit-tests and dispatches it, so a tap the
    // surface refuses or a recognizer swallows fails the test. Needs the host
    // app, which is why this suite runs hosted by the sample app.
    if let point {
        try TouchSynthesizer.tap(at: pointOnScreen(point, in: window), in: window)
        return
    }
    let what: String
    let matches: (NSObject) -> Bool
    if let id {
        what = "id \"\(id)\""
        matches = { YamlWorld.identifier(of: $0) == id }
    } else if let label {
        // The accessibility label of a control that shows no text, whole.
        what = "label \"\(label)\""
        matches = { $0.accessibilityLabel == label }
    } else if exact {
        what = "exact text \"\(text!)\""
        matches = { YamlWorld.shownText(of: $0) == text! }
    } else {
        what = "text \"\(text!)\""
        matches = { YamlWorld.shownText(of: $0)?.contains(text!) == true }
    }
    // The story viewer's page reads out as one accessibility node holding
    // every label on it, so its controls have no frame of their own to tap:
    // the touch goes where the viewer lays them out instead (the CTA above
    // the bottom safe area, the chrome buttons in a row under the indicator).
    if SDKInstance.shared.controller.activeStoryOverlay != nil,
       (label != nil || text != nil),
       YamlWorld.find(in: window, where: matches) != nil,
       let viewerTap = storyViewerTapPoint(window, label: label, hasText: text != nil)
    {
        try TouchSynthesizer.tap(at: viewerTap, in: window)
        return
    }
    try await tapSettled(world, window, what: what, exactlyOne: exact, matches)
}

/// Two quick taps with no settling between them, as a user double-tapping:
/// the second tap lands in the same presentation, the way two rapid taps do.
/// Takes an element id or a text, resolved exactly like tapOn's.
@MainActor private func doubleTapOn(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let id = args["id"] as? String
    let text = args["text"] as? String
    let exact = args["exact"] as? Bool ?? false
    guard [id, text].compactMap({ $0 }).count == 1 else {
        throw YamlTestFailure(
            "needs exactly one of id, text",
            expected: "doubleTapOn: { id: ... } | { text: ... }",
            actual: "\(args)")
    }
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    let what: String
    let matches: (NSObject) -> Bool
    if let id {
        what = "id \"\(id)\""
        matches = { YamlWorld.identifier(of: $0) == id }
    } else if exact {
        what = "exact text \"\(text!)\""
        matches = { YamlWorld.shownText(of: $0) == text! }
    } else {
        what = "text \"\(text!)\""
        matches = { YamlWorld.shownText(of: $0)?.contains(text!) == true }
    }
    let point = try await resolveTapPoint(world, window, what: what, exactlyOne: exact, matches)
    try TouchSynthesizer.tap(at: point, in: window)
    TouchSynthesizer.drainRunLoop(for: 0.08)
    try TouchSynthesizer.tap(at: point, in: window)
}

/// Waits for the first element matching to stop moving (a surface's entry
/// animation would otherwise send the touch to where it *was*; the frame
/// must hold for 400 ms), then taps its centre. [exactlyOne]: 0 or more than
/// one match is a step error. Mirrors the hosted harness's `tap(text:)`.
@MainActor private func tapSettled(
    _ world: YamlWorld, _ window: UIWindow, what: String, exactlyOne: Bool,
    _ matches: @escaping (NSObject) -> Bool
) async throws {
    let point = try await resolveTapPoint(world, window, what: what, exactlyOne: exactlyOne, matches)
    try TouchSynthesizer.tap(at: point, in: window)
}

/// Waits for the first element matching to stop moving and returns where to
/// tap it, without touching anything. Shared by the single- and double-tap.
@MainActor private func resolveTapPoint(
    _ world: YamlWorld, _ window: UIWindow, what: String, exactlyOne: Bool,
    _ matches: @escaping (NSObject) -> Bool
) async throws -> CGPoint {
    var last: CGRect?
    var steadyReads = 0
    do {
        try await world.waitUntil("an element with \(what) settled on screen", timeout: 4) {
            if exactlyOne {
                let all = YamlWorld.findAll(in: window, where: matches)
                guard all.count == 1 else {
                    steadyReads = 0
                    last = nil
                    return false
                }
                let frame = all[0].accessibilityFrame
                guard !frame.isEmpty else { return false }
                steadyReads = frame == last ? steadyReads + 1 : 0
                last = frame
                return steadyReads >= 2
            }
            guard let frame = YamlWorld.find(in: window, where: matches)?.accessibilityFrame,
                  !frame.isEmpty
            else {
                return false
            }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 2
        }
    } catch {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "an element with \(what) on screen",
            actual: "no settled match after 8s; texts on screen: \(world.visibleTexts)",
            line: world.step.line)
    }
    guard var frame = last else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "an element with \(what) on screen",
            actual: "no match",
            line: world.step.line)
    }
    if exactlyOne {
        let all = YamlWorld.findAll(in: window, where: matches)
        if all.count != 1 {
            throw YamlTestFailure(
                "tapOn exact: \(all.count) elements match",
                expected: "exactly one element with \(what)",
                actual: all.map { "\(YamlWorld.shownText(of: $0) ?? "?") at \($0.accessibilityFrame)" }
                    .joined(separator: "; "),
                line: world.step.line)
        }
        frame = all[0].accessibilityFrame
    }
    let pointInWindow = window.convert(frame, from: window.screen.coordinateSpace)
    return CGPoint(x: pointInWindow.midX, y: pointInWindow.midY)
}

/// A real touch on the scrim outside the presented campaign: top-centre, above
/// the card, the same spot every stack taps. A locked backdrop swallows it; a
/// dismissible one closes the campaign.
@MainActor private func tapOutside(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    let size = window.bounds.size
    try TouchSynthesizer.tap(
        at: CGPoint(x: size.width * 0.5, y: size.height * 0.12), in: window)
    await world.settle()
}

/// A real touch on the presented campaign's close (x) button: the `Button`
/// labelled "Close", matched exactly so campaign copy mentioning "close"
/// never matches. A floating window (PiP or story floater) carries no label,
/// so when no labelled close is settled, fall back to its top-right chrome
/// (as tapFloating close does). Settles like `tap(label:)` does.
@MainActor private func tapCloseButton(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    // "Close", or starting "Close " (a survey's is "Close survey").
    let matches: (NSObject) -> Bool = {
        guard $0.accessibilityTraits.contains(.button), let text = YamlWorld.shownText(of: $0)
        else { return false }
        return text == "Close" || text.hasPrefix("Close ")
    }
    var last: CGRect?
    var steadyReads = 0
    do {
        try await world.waitUntil("a close button settled on screen", timeout: 3) {
            guard let frame = YamlWorld.find(in: window, where: matches)?.accessibilityFrame,
                  !frame.isEmpty
            else {
                return false
            }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 2
        }
    } catch {
        // No labelled close: a floating window's × has no label. Fall back to
        // its top-right chrome, as tapFloating close does. The rect publishes
        // async after the window draws, so wait for it.
        let sdk = SDKInstance.shared
        do {
            try await world.waitUntil("a floating window to tap", timeout: 5) {
                sdk.floaterOrchestrator.activeRect != nil || sdk.floaterStoryOrchestrator.activeRect != nil
            }
        } catch {
            throw YamlTestFailure(
                "no close button on screen",
                expected: "a presented campaign with a close button",
                actual: "no settled match after 3s",
                line: world.step.line)
        }
        guard let rect = sdk.floaterOrchestrator.activeRect ?? sdk.floaterStoryOrchestrator.activeRect else {
            throw YamlTestFailure(
                "no close button on screen",
                expected: "a presented campaign with a close button",
                actual: "no settled match after 3s",
                line: world.step.line)
        }
        let rectInWindow = window.convert(rect, from: window.screen.coordinateSpace)
        // Wait for the chrome buttons to appear, as the harness does
        // (waitForPipWindow/waitForStoryWindow checks activeRect, then the test
        // finds floaterButtons). Tapping the corner point when no button is
        // found misses and leaves the window up (f06/f10 assertNotVisible).
        do {
            try await world.waitUntil("a floating close button", timeout: 5) {
                YamlWorld.findAll(in: window) { $0.accessibilityTraits.contains(.button) }
                    .map { $0.accessibilityFrame }.filter { !$0.isEmpty }.map {
                        window.convert($0, from: window.screen.coordinateSpace)
                    }.map { CGPoint(x: $0.midX, y: $0.midY) }
                    .contains { rectInWindow.contains($0) }
            }
        } catch {
            throw YamlTestFailure(
                "no close button on screen",
                expected: "a floating close button in the window",
                actual: "none showing",
                line: world.step.line)
        }
        // The window flies in on appear; a tap during the entry animation
        // lands where the button was, not where it is. Settle like the
        // harness does after the window is drawn, then find and tap.
        ComponentTestHost.drainRunLoop(for: 0.05)
        let found = YamlWorld.findAll(in: window) {
            $0.accessibilityTraits.contains(.button)
        }
        let pts = found.map { $0.accessibilityFrame }.filter { !$0.isEmpty }.map {
            window.convert($0, from: window.screen.coordinateSpace)
        }.map { CGPoint(x: $0.midX, y: $0.midY) }
        let point = CGPoint(x: rectInWindow.maxX, y: rectInWindow.minY)
        guard let best = pts.filter({ rectInWindow.contains($0) }).min(by: {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        }) else {
            throw YamlTestFailure(
                "no close button on screen",
                expected: "a floating close button in the window",
                actual: "none showing",
                line: world.step.line)
        }
        try TouchSynthesizer.tap(at: best, in: window)
        await world.settle()
        return
    }
    guard let frame = last else {
        throw YamlTestFailure(
            "no close button on screen",
            expected: "a presented campaign with a close button",
            actual: "no match",
            line: world.step.line)
    }
    let pointInWindow = window.convert(frame, from: window.screen.coordinateSpace)
    try TouchSynthesizer.tap(
        at: CGPoint(x: pointInWindow.midX, y: pointInWindow.midY), in: window)
    await world.settle()
}

/// Closes the story viewer the way an iOS user does: a swipe down on it,
/// which iOS has instead of a system back gesture. Mirrors the harness's
/// swipe-down dismiss (midX, 35% height, +300 over 0.15 s).
@MainActor private func dismissStoryViewer(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let sdk = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to dismiss",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    let size = window.bounds.size
    // Wait for the viewer to be presented and its cross-dissolve to finish,
    // like the harness's waitForStoryViewer: a touch during the dissolve
    // reaches the page under the viewer instead of the viewer itself. Either
    // surface counts: an inline viewer registers with the SDK, a canvas one
    // only presents. Polled on the main actor (a waitUntil closure would read
    // UIKit off-main).
    do {
        let deadline = Date().addingTimeInterval(5)
        var ready = false
        while !ready, Date() <= deadline {
            if let presented = presentedStoryViewer(world),
               !presented.isBeingPresented, presented.view.window != nil
            {
                ready = true
            } else {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        if !ready { throw YamlTestFailure("the story viewer did not open") }
    } catch {
        throw YamlTestFailure(
            "the story viewer did not open",
            expected: "a presented viewer after opening its strip",
            actual: "none showing",
            line: world.step.line)
    }
    ComponentTestHost.drainRunLoop(for: 0.05)
    // The same swipe down the generic swipe runs for s11 (which closes): from
    // mid-screen down 300 pt, clear of any story CTA button.
    try TouchSynthesizer.drag(
        from: CGPoint(x: size.width * 0.5, y: size.height * 0.35),
        by: CGVector(dx: 0, dy: 300),
        in: window,
        duration: 0.15)
    // The viewer reports Step Dismissed as it leaves; wait for it to go,
    // like the harness's waitForStoryViewerClosed, so a following assertion
    // sees the closed state rather than a mid-flight frame.
    do {
        let deadline = Date().addingTimeInterval(5)
        var gone = presentedStoryViewer(world) == nil
        while !gone, Date() <= deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            gone = presentedStoryViewer(world) == nil
        }
        if !gone { throw YamlTestFailure("the story viewer did not close") }
    } catch {
        throw YamlTestFailure(
            "the story viewer did not close",
            expected: "a dismissed viewer after the swipe down",
            actual: "still showing",
            line: world.step.line)
    }
    await world.settle()
}

/// A real drag starting at the centre of the element with id or text, for the
/// bottom-sheet threshold tests. Mirrors the hosted harness's drag support.
@MainActor private func swipe(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to swipe",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    let id = args["id"] as? String
    let text = args["text"] as? String
    let point = args["point"] as? String
    guard [id, text, point].compactMap({ $0 }).count == 1 else {
        throw YamlTestFailure(
            "swipe needs exactly one of id, text, point",
            expected: "swipe: { id|text|point, direction, distance }",
            actual: "\(args)")
    }
    guard let direction = args["direction"] as? String,
          ["up", "down", "left", "right"].contains(direction) else {
        throw YamlTestFailure(
            "bad swipe direction",
            expected: "up, down, left or right",
            actual: "\(args["direction"] ?? "none")")
    }
    let distance = (args["distance"] as? NSNumber)?.doubleValue ?? 500
    let velocity = (args["velocity"] as? NSNumber)?.doubleValue
    let translation: CGVector = switch direction {
    case "down": CGVector(dx: 0, dy: distance)
    case "up": CGVector(dx: 0, dy: -distance)
    case "left": CGVector(dx: -distance, dy: 0)
    default: CGVector(dx: distance, dy: 0)
    }
    // Without velocity a slow drag (0.6 s); with velocity (pixels/sec) a fling.
    let duration: Double
    if let velocity {
        guard velocity > 0 else {
            throw YamlTestFailure(
                "bad swipe velocity",
                expected: "pixels per second > 0",
                actual: "\(velocity)")
        }
        duration = max(0.03, distance / velocity)
    } else {
        duration = 0.6
    }
    if let point {
        // Content with no id or text (a full-screen story viewer): the finger
        // lands at the point, like tapOn's.
        let start = try pointOnScreen(point, in: window)
        try TouchSynthesizer.drag(from: start, by: translation, in: window, duration: duration)
        // `settle: false` leaves animations running: a story viewer's progress
        // never idles, so settling after a swipe on it would fast-forward it.
        if args["settle"] as? Bool != false {
            await world.settle()
        }
        return
    }
    let matches: (NSObject) -> Bool
    let what: String
    if let id {
        what = "id \"\(id)\""
        matches = { YamlWorld.identifier(of: $0) == id }
    } else {
        what = "text \"\(text!)\""
        matches = { YamlWorld.shownText(of: $0)?.contains(text!) == true }
    }
    var last: CGRect?
    var steadyReads = 0
    do {
        try await world.waitUntil("an element with \(what) settled on screen", timeout: 4) {
            guard let frame = YamlWorld.find(in: window, where: matches)?.accessibilityFrame,
                  !frame.isEmpty
            else {
                return false
            }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 2
        }
    } catch {
        throw YamlTestFailure(
            "nothing to swipe",
            expected: "an element with \(what) on screen",
            actual: "no settled match after 8s",
            line: world.step.line)
    }
    guard let frame = last else {
        throw YamlTestFailure(
            "nothing to swipe",
            expected: "an element with \(what) on screen",
            actual: "no match",
            line: world.step.line)
    }
    let frameInWindow = window.convert(frame, from: window.screen.coordinateSpace)
    let start = CGPoint(x: frameInWindow.midX, y: frameInWindow.midY)
    try TouchSynthesizer.drag(from: start, by: translation, in: window, duration: duration)
    if args["settle"] as? Bool != false {
        await world.settle()
    }
}

/// A tap on a floating window's chrome by role: close, expand, collapse,
/// window, mute or playPause. The chrome's glyph buttons carry no
/// accessibility label, so a control is found by where it sits: the PiP's
/// chrome corners are fixed by design (collapsed: close top-right, expand
/// bottom-left, mute/play bottom-right; expanded: close top-right, collapse
/// top-left), and the window itself is tapped at its centre.
@MainActor private func tapFloating(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    guard let target = args["target"] as? String,
          ["close", "expand", "collapse", "window", "mute", "playPause"].contains(target)
    else {
        throw YamlTestFailure(
            "bad tapFloating target",
            expected: "close, expand, collapse, window, mute or playPause",
            actual: "\(args["target"] ?? "none")")
    }
    let sdk = SDKInstance.shared
    // The rect is published async after the window draws (onAppear), so wait
    // for it — isShowing can already be true while it is still nil.
    do {
        try await world.waitUntil("a floating window to tap", timeout: 5) {
            sdk.floaterOrchestrator.activeRect != nil || sdk.floaterStoryOrchestrator.activeRect != nil
        }
    } catch {
        throw YamlTestFailure(
            "no floating window on screen",
            expected: "a floating window to tap",
            actual: "none showing",
            line: world.step.line)
    }
    let pipRect = sdk.floaterOrchestrator.activeRect
    let storyRect = sdk.floaterStoryOrchestrator.activeRect
    guard let rect = pipRect ?? storyRect else {
        throw YamlTestFailure(
            "no floating window on screen",
            expected: "a floating window to tap",
            actual: "none showing",
            line: world.step.line)
    }
    let rectInWindow = window.convert(rect, from: window.screen.coordinateSpace)
    func buttons() -> [CGPoint] {
        let found = YamlWorld.findAll(in: window) {
            $0.accessibilityTraits.contains(.button)
        }
        return found.map { $0.accessibilityFrame }.filter { !$0.isEmpty }.map {
            window.convert($0, from: window.screen.coordinateSpace)
        }.map { CGPoint(x: $0.midX, y: $0.midY) }
    }
    func nearest(_ point: CGPoint) throws -> CGPoint {
        let all = buttons().filter { rectInWindow.contains($0) }
        guard let best = all.min(by: {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        }) else {
            throw YamlTestFailure(
                "no floating \(target) button on screen",
                expected: "a \(target) control",
                actual: "no match",
                line: world.step.line)
        }
        return best
    }
    switch target {
    case "close":
        let point = CGPoint(x: rectInWindow.maxX, y: rectInWindow.minY)
        // Wait for the chrome buttons, as tapCloseButton does — tapping the
        // corner point when no button is found misses and leaves the window up.
        do {
            try await world.waitUntil("a floating close button", timeout: 5) {
                buttons().contains { rectInWindow.contains($0) }
            }
        } catch {
            throw YamlTestFailure(
                "no floating close button on screen",
                expected: "a close control",
                actual: "no match",
                line: world.step.line)
        }
        // The window flies in on appear; a tap during the entry animation
        // lands where the button was, not where it is. Settle like the
        // harness does after the window is drawn, then re-find and tap.
        ComponentTestHost.drainRunLoop(for: 0.05)
        try TouchSynthesizer.tap(at: try nearest(point), in: window)
        await world.settle()
    case "expand":
        // The window tap expands too (reports pip_media rather than pip_expand,
        // but the same Clicked + Step Viewed chain); prefer the pill when it is there.
        let point = CGPoint(x: rectInWindow.minX, y: rectInWindow.maxY)
        if let pill = try? nearest(point) {
            try TouchSynthesizer.tap(at: pill, in: window)
        } else {
            try TouchSynthesizer.tap(at: CGPoint(x: rectInWindow.midX, y: rectInWindow.midY), in: window)
        }
    case "collapse":
        // The collapse control is the pill's leftmost button, and the pill
        // sits at the top corner opposite the ×: `closePlacement: top_left`
        // (as here) puts the × top-left and the pill top-right; the default
        // puts the × top-right and the pill top-left. Read the served fixture
        // so the tap lands on collapse whatever the author chose — tapping
        // the × instead ends the showing as user_close.
        let closeOnLeft = world.campaigns.contains { entry in
            ((entry["templateConfig"] as? [String: Any])?["expanded"] as? [String: Any])?["closePlacement"] as? String == "top_left"
        }
        let top = CGRect(x: 0, y: 0, width: window.bounds.width, height: 200)
        let side = buttons().filter { top.contains($0) && ($0.x > rectInWindow.midX) == closeOnLeft }
        if let best = side.min(by: { $0.x < $1.x }) {
            try TouchSynthesizer.tap(at: best, in: window)
        } else {
            let corner = closeOnLeft
                ? CGPoint(x: rectInWindow.maxX, y: rectInWindow.minY)
                : CGPoint(x: rectInWindow.minX, y: rectInWindow.minY)
            try TouchSynthesizer.tap(at: (try? nearest(corner)) ?? corner, in: window)
        }
    case "window":
        try TouchSynthesizer.tap(at: CGPoint(x: rectInWindow.midX, y: rectInWindow.midY), in: window)
    case "mute", "playPause":
        // Bottom-right pill: play/pause beside mute. Tap the rightmost there
        // for mute, the leftmost for play/pause — the harness taps pill[0]
        // (leftmost) to pause and nearest bottom-right (rightmost) for mute.
        let pill = buttons().filter { $0.x > rectInWindow.midX && $0.y > rectInWindow.midY }.sorted { $0.x < $1.x }
        guard !pill.isEmpty else {
            throw YamlTestFailure(
                "no floating \(target) button on screen",
                expected: "a \(target) control",
                actual: "no match",
                line: world.step.line)
        }
        try TouchSynthesizer.tap(at: target == "mute" ? pill[pill.count - 1] : pill[0], in: window)
    default:
        throw YamlTestFailure("bad tapFloating target", actual: target, line: world.step.line)
    }
    await world.settle()
}

/// A drag on the floating window from its centre: a slow drag snaps to the
/// nearer corner, a fling (velocity pixels/sec) to the thrown corner.
@MainActor private func dragFloating(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to drag",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    guard let direction = args["direction"] as? String,
          ["up", "down", "left", "right"].contains(direction) else {
        throw YamlTestFailure(
            "bad dragFloating direction",
            expected: "up, down, left or right",
            actual: "\(args["direction"] ?? "none")")
    }
    let distance = (args["distance"] as? NSNumber)?.doubleValue ?? 500
    let velocity = (args["velocity"] as? NSNumber)?.doubleValue
    let translation: CGVector = switch direction {
    case "down": CGVector(dx: 0, dy: distance)
    case "up": CGVector(dx: 0, dy: -distance)
    case "left": CGVector(dx: -distance, dy: 0)
    default: CGVector(dx: distance, dy: 0)
    }
    let duration: Double
    if let velocity {
        guard velocity > 0 else {
            throw YamlTestFailure(
                "bad dragFloating velocity",
                expected: "pixels per second > 0",
                actual: "\(velocity)")
        }
        duration = max(0.03, distance / velocity)
    } else {
        duration = 0.6
    }
    let sdk = SDKInstance.shared
    do {
        try await world.waitUntil("a floating window to drag", timeout: 5) {
            sdk.floaterOrchestrator.activeRect != nil || sdk.floaterStoryOrchestrator.activeRect != nil
        }
    } catch {
        throw YamlTestFailure(
            "no floating window on screen",
            expected: "a floating window to drag",
            actual: "none showing",
            line: world.step.line)
    }
    guard let rect = sdk.floaterOrchestrator.activeRect ?? sdk.floaterStoryOrchestrator.activeRect else {
        throw YamlTestFailure(
            "no floating window on screen",
            expected: "a floating window to drag",
            actual: "none showing",
            line: world.step.line)
    }
    let rectInWindow = window.convert(rect, from: window.screen.coordinateSpace)
    let start = CGPoint(x: rectInWindow.midX, y: rectInWindow.midY)
    try TouchSynthesizer.drag(from: start, by: translation, in: window, duration: duration)
    ComponentTestHost.drainRunLoop(for: 0.05)
    await world.settle()
}

/// The PiP's sound state: the floater orchestrator's muted flag and the PiP
/// player's own `isMuted` both read as `muted`. Polls briefly, as a mute tap
/// lands a beat after the step.
@MainActor private func assertPipMuted(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let want = args["muted"] as? Bool else {
        throw YamlTestFailure(
            "assertPipMuted needs muted",
            expected: "assertPipMuted: { muted: <bool> }",
            actual: "\(args)",
            line: world.step.line)
    }
    let sdk = try world.sdk
    do {
        try await world.waitUntil("the PiP muted state", timeout: 3) {
            guard let orchestrator = sdk.floaterOrchestrator else { return false }
            guard orchestrator.muted == want else { return false }
            guard let player = orchestrator.player else { return false }
            return player.isMuted == want
        }
    } catch {
        let muted = sdk.floaterOrchestrator?.muted
        let playerMuted = sdk.floaterOrchestrator?.player?.isMuted
        throw YamlTestFailure(
            "the PiP plays \(muted.map { $0 ? "muted" : "with sound" } ?? "nowhere")",
            expected: "muted: \(want)",
            actual: "orchestrator muted: \(muted.map(String.init(describing:)) ?? "none"), "
                + "player isMuted: \(playerMuted.map(String.init(describing:)) ?? "none")",
            line: world.step.line)
    }
}

/// `"50%,90%"` of the window, in points.
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

/// Compares the phone frame with the existing baseline
/// `goldens/ios/<name>`, in verify mode only: a missing baseline fails
/// instead of recording one, and record mode never writes.
@MainActor private func takeScreenshot(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let name = args["name"] as? String else {
        throw YamlTestFailure("takeScreenshot needs a name", line: world.step.line)
    }
    guard world.onPhone || world.onTablet, let window = world.window else {
        throw YamlTestFailure(
            "takeScreenshot needs launchApp with host: phone or tablet",
            expected: "the golden frame the baselines are drawn on",
            line: world.step.line)
    }
    var image = ComponentTestHost.renderImage(of: window)
    let parts = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
    let split = parts.split(separator: "/", maxSplits: 1).map(String.init)
    guard split.count == 2 else {
        throw YamlTestFailure(
            "bad screenshot name \"\(name)\"",
            expected: "a path like nudge_dialog/nudge_dialog.png",
            line: world.step.line)
    }
    let (surface, file) = (split[0], split[1])
    guard let workspace = FixtureLoader.workspaceURL(),
          let data = try? Data(contentsOf: workspace
              .appendingPathComponent("goldens/ios/\(surface)/\(file).png"))
    else {
        throw YamlTestFailure(
            "no iOS baseline for \(name)",
            expected: "a committed goldens/ios/\(surface)/\(file).png; the driver never records",
            line: world.step.line)
    }
    let diffing = Diffing<UIImage>.image(precision: 1.0, perceptualPrecision: 0.98)
    let reference = diffing.fromData(data)
    var mismatch = diffing.diffV2(reference, image)
    if mismatch != nil {
        image = ComponentTestHost.settledImage(of: window)
        mismatch = diffing.diffV2(reference, image)
    }
    if let (message, attachments) = mismatch {
        Attachment.record(image, named: "\(surface)-\(file)-actual", as: .png)
        Attachment.record(reference, named: "\(surface)-\(file)-reference", as: .png)
        for attachment in attachments {
            guard case .data(let difference, let attachmentName) = attachment,
                  attachmentName == "difference.png"
            else { continue }
            Attachment.record(difference, named: "\(surface)-\(file)-difference.png")
        }
        throw YamlTestFailure(
            "\(surface)/\(file): \(message)",
            line: world.step.line)
    }
}

/// The YAML `assertGolden` command: compares the screen with the stack's own
/// recorded golden `goldens/ios/<test-file-stem>/<name>.png` under
/// testkit/sdk-tests (each stack records and compares only its own), reusing
/// SnapshotTesting's image diffing and the golden phone frame. With `campaign`
/// (a served campaign key) just that campaign's surface is captured instead
/// of the whole host screen. `tolerance` (optional) is the largest fraction
/// of pixels, 0 to 1, that may differ; without it the pinned exact config
/// stays. A missing golden is recorded and the step passes, unless
/// `YAML_GOLDENS_STRICT=1` fails it instead (for CI);
/// `YAML_GOLDENS_UPDATE=1` re-records (pass as `TEST_RUNNER_YAML_GOLDENS_UPDATE=1`:
/// xcodebuild forwards `TEST_RUNNER_*` to the test host without the prefix).
/// Needs `launchApp` with `host: phone`.
@MainActor private func assertGolden(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let rawName = (args["name"] as? String) ?? ""
    let campaign = args["campaign"] as? String
    let tolerance = try goldenTolerance(args["tolerance"], world)
    let name = rawName.hasSuffix(".png") ? String(rawName.dropLast(4)) : rawName
    guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
        throw YamlTestFailure(
            "bad golden name \"\(rawName)\"",
            expected: "a file name such as overlay_welcome (no path)",
            line: world.step.line)
    }
    guard world.onPhone || world.onTablet, let window = world.window else {
        throw YamlTestFailure(
            "assertGolden needs launchApp with host: phone or tablet",
            expected: "the fixed surface the goldens are recorded on (390x844 phone, 1024x768 tablet)",
            line: world.step.line)
    }
    // Story strips show remote (picsum) images through the SDWebImage stub:
    // the stub answers synchronously but decode and the SwiftUI redraw land
    // asynchronously, so a capture right after the settle drain sometimes
    // catches the placeholder and the golden flakes. Drain until the image
    // pipeline is idle (bounded), so the capture sees the served image.
    let imagesIdleBy = Date().addingTimeInterval(5)
    while (SDWebImageManager.shared.isRunning || DigiaImagePipeline.imageManager.isRunning) && Date() < imagesIdleBy {
        ComponentTestHost.drainRunLoop(for: 0.1)
    }
    ComponentTestHost.drainRunLoop(for: 0.01)
    // Canvas Lotties outside `CanvasRemoteLottie` (classic-nudge `NudgeLottieView`,
    // floater `FloaterMediaView`) do not read `canvasLottieRuntime`: they play on
    // wall-clock time, so pin every Lottie to its mid-frame before each capture,
    // mirroring `PipGoldenTests.holdLottie`.
    holdYamlLottie(in: window)
    var image = ComponentTestHost.renderImage(of: window)
    if let campaign {
        image = try cropToCampaign(world, campaign, image, window)
    }
    guard let workspace = FixtureLoader.workspaceURL() else {
        throw YamlTestFailure(
            "no de_workspace found",
            expected: "the goldens beside the checkout",
            line: world.step.line)
    }
    let baseline = workspace.appendingPathComponent(
        "testkit/sdk-tests/goldens/ios/\(world.testStem)/\(name).png")
    let display = "testkit/sdk-tests/goldens/ios/\(world.testStem)/\(name).png"
    let update = ProcessInfo.processInfo.environment["YAML_GOLDENS_UPDATE"] == "1"
    let strict = ProcessInfo.processInfo.environment["YAML_GOLDENS_STRICT"] == "1"
    let exists = FileManager.default.fileExists(atPath: baseline.path)
    if update || !exists {
        if !exists && strict && !update {
            throw YamlTestFailure(
                "no iOS golden for \(name)",
                expected: "a recorded \(display); run without YAML_GOLDENS_STRICT=1 to record it",
                line: world.step.line)
        }
        // Record the settled frame (matching the retry path below) so
        // animations like survey height transitions finish before capture.
        ComponentTestHost.drainRunLoop(for: 0.35)
        holdYamlLottie(in: window)
        image = ComponentTestHost.settledImage(of: window)
        if let campaign {
            image = try cropToCampaign(world, campaign, image, window)
        }
        guard let png = image.pngData() else {
            throw YamlTestFailure("could not encode the screen capture", line: world.step.line)
        }
        try FileManager.default.createDirectory(
            at: baseline.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: baseline)
        print("\(update ? "updated" : "recorded new") golden \(display)")
        return
    }
    guard let data = try? Data(contentsOf: baseline) else {
        throw YamlTestFailure(
            "could not read \(display)",
            line: world.step.line)
    }
    // The pinned config stays when no tolerance is given: exact pixels
    // (precision 1.0) with the perceptual slack the hand-written goldens use.
    let precision: Float = tolerance.map { 1 - Float($0) } ?? 1.0
    let diffing = Diffing<UIImage>.image(precision: precision, perceptualPrecision: 0.98)
    let reference = diffing.fromData(data)
    var mismatch = diffing.diffV2(reference, image)
    if mismatch != nil {
        // Retry once after a full settle drain for slow async renderers (e.g. dotLottie unzip,
        // carousel/story transitions) while keeping the fast path for already-settled frames.
        ComponentTestHost.drainRunLoop(for: 0.35)
        holdYamlLottie(in: window)
        image = ComponentTestHost.settledImage(of: window)
        if let campaign {
            image = try cropToCampaign(world, campaign, image, window)
        }
        mismatch = diffing.diffV2(reference, image)
    }
    if let (message, attachments) = mismatch {
        Attachment.record(image, named: "\(world.testStem)-\(name)-actual", as: .png)
        Attachment.record(reference, named: "\(world.testStem)-\(name)-reference", as: .png)
        for attachment in attachments {
            guard case .data(let difference, let attachmentName) = attachment,
                  attachmentName == "difference.png"
            else { continue }
            Attachment.record(difference, named: "\(world.testStem)-\(name)-difference.png")
        }
        throw YamlTestFailure(
            "golden mismatch ios/\(world.testStem)/\(name): \(message)",
            expected: "pixels matching \(display)",
            line: world.step.line)
    }
}

/// Pauses every Lottie in the window at its mid-frame, mirroring
/// `PipGoldenTests.holdLottie`: the canvas seam covers `CanvasRemoteLottie`,
/// but classic-nudge and floater Lotties play on wall-clock time.
@MainActor private func holdYamlLottie(in view: UIView) {
    if let lottie = view as? LottieAnimationView {
        lottie.setPlaybackMode(.paused(at: .progress(0.5)))
    }
    view.subviews.forEach { holdYamlLottie(in: $0) }
}

/// tolerance is `json`: a fraction 0..1; nil keeps the pinned exact config.
@MainActor private func goldenTolerance(_ value: Any?, _ world: YamlWorld) throws -> Double? {
    guard let value else { return nil }
    let t: Double
    if let d = value as? Double { t = d }
    else if let i = value as? Int { t = Double(i) }
    else {
        throw YamlTestFailure(
            "bad tolerance \"\(value)\"",
            expected: "a fraction 0..1",
            line: world.step.line)
    }
    guard !t.isNaN, t >= 0, t <= 1 else {
        throw YamlTestFailure(
            "bad tolerance \"\(value)\"",
            expected: "a fraction 0..1",
            line: world.step.line)
    }
    return t
}

/// The campaign's visible content bounds: the union of the on-screen frames of
/// every text the served campaign shows (its copy and button labels, read
/// from its served JSON), padded and clamped to the screen. Fails when the
/// campaign is not showing. The settled image is @1x, so points are pixels.
@MainActor private func cropToCampaign(
    _ world: YamlWorld, _ campaign: String, _ image: UIImage, _ window: UIWindow
) throws -> UIImage {
    let served = world.campaigns.filter { ($0["campaignKey"] as? String) == campaign }
    guard !served.isEmpty else {
        throw YamlTestFailure(
            "unknown campaign \"\(campaign)\"",
            expected: "a campaign key mockApi is serving",
            line: world.step.line)
    }
    var wanted = Set<String>()
    for entry in served { collectDisplayStrings(entry, into: &wanted) }
    var bounds: CGRect?
    for text in wanted where !text.isEmpty {
        // Substring: a button's shown label may carry surrounding whitespace
        // or combine spans the fixture writes apart; the crop only bounds.
        let matches = YamlWorld.findAll(in: window) {
            $0.accessibilityLabel == text || ($0.accessibilityLabel?.contains(text) == true)
                || YamlWorld.shownText(of: $0) == text
                || (YamlWorld.shownText(of: $0)?.contains(text) == true)
        }
        for found in matches {
            let frame = window.convert(found.accessibilityFrame, from: window.screen.coordinateSpace)
            bounds = bounds?.union(frame) ?? frame
        }
    }
    guard var box = bounds, !box.isNull, !box.isEmpty else {
        throw YamlTestFailure(
            "campaign \"\(campaign)\" is not showing",
            expected: "its content on screen (texts: \(wanted.sorted()))",
            actual: "no match",
            line: world.step.line)
    }
    box = box.insetBy(dx: -12, dy: -12)
        .intersection(CGRect(origin: .zero, size: image.size))
    guard !box.isNull, !box.isEmpty, let cropped = image.cgImage?.cropping(to: box) else {
        throw YamlTestFailure("could not crop to campaign \"\(campaign)\"", line: world.step.line)
    }
    return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
}

/// Every string under a display key (`text`, `title`, `message`, `label`) in
/// the served campaign: the copy a golden of its surface must show.
private func collectDisplayStrings(_ value: Any, into out: inout Set<String>) {
    if let map = value as? [String: Any] {
        for (key, entry) in map {
            if displayKeys.contains(key), let text = entry as? String, !text.isEmpty {
                out.insert(text)
            }
            collectDisplayStrings(entry, into: &out)
        }
    } else if let list = value as? [Any] {
        for entry in list { collectDisplayStrings(entry, into: &out) }
    }
}

private let displayKeys: Set<String> = ["text", "title", "message", "label"]

/// Replaces the content of the one editable field on screen, as a paste:
/// the field's own editing path runs (UITextField `insertText` /
/// UITextView `insertText`), so SwiftUI's binding and the survey hear it as a
/// typed edit; keyboard-level filtering is bypassed. `""` clears.
@MainActor private func inputText(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure("nothing to type into", expected: "launchApp before this command",
                              line: world.step.line)
    }
    let text = args["text"] as? String ?? ""
    let into = args["into"] as? String
    func placeholder(_ view: UIView) -> String? {
        if let field = view as? UITextField {
            return field.placeholder ?? field.attributedPlaceholder?.string ?? field.accessibilityLabel
        }
        return view.accessibilityLabel
    }
    func editable(_ object: NSObject) -> Bool {
        guard let view = object as? UIView, view.window != nil else { return false }
        let ok: Bool
        if let field = view as? UITextField { ok = field.isEnabled }
        else if let textView = view as? UITextView { ok = textView.isEditable }
        else { return false }
        guard ok, into == nil || placeholder(view) == into else { return false }
        // Only the field a finger would reach: a copy laid out off-screen or
        // under another view (a measuring pass) does not count.
        let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
        guard let hit = window.hitTest(center, with: nil) else { return false }
        return hit === view || hit.isDescendant(of: view)
    }
    var fields: [UIView] = []
    do {
        try await world.waitUntil("an editable field on screen", timeout: 5) {
            // One per on-screen position: the same field can be reached twice.
            var seen = Set<String>()
            fields = YamlWorld.findAll(in: window, where: editable).compactMap { $0 as? UIView }
                .filter { field in
                    let f = field.convert(field.bounds, to: window).integral
                    return seen.insert("\(f.minX),\(f.minY),\(f.width),\(f.height)").inserted
                }
            return !fields.isEmpty
        }
    } catch {
        throw YamlTestFailure(
            "no editable field on screen",
            expected: into.map { "a field whose placeholder is \"\($0)\"" } ?? "one editable text field",
            actual: "texts on screen: \(world.visibleTexts)",
            line: world.step.line)
    }
    guard fields.count == 1, let field = fields.first else {
        throw YamlTestFailure(
            "\(fields.count) editable fields match",
            expected: "exactly one (give into: its placeholder)",
            actual: fields.map { "\(type(of: $0)) \($0.accessibilityFrame) in \(type(of: $0.superview as Any))" }
                .joined(separator: "; "),
            line: world.step.line)
    }
    _ = field.becomeFirstResponder()
    if let input = field as? (UIView & UITextInput) {
        if let all = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument),
           !all.isEmpty
        {
            input.selectedTextRange = all
            if text.isEmpty {
                input.deleteBackward()
            }
        }
        if !text.isEmpty { input.insertText(text) }
    }
    await world.settle()
}

/// Opens the one date field's picker (a tap on the field), sets [date] on
/// its `UIDatePicker` and taps Done (or Cancel). iOS's picker is a wheel in
/// an alert; the driver sets the wheel's date as a spin would end on it.
@MainActor private func pickDate(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let sdk = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure("nothing to tap", expected: "launchApp before this command",
                              line: world.step.line)
    }
    let text = args["date"] as? String ?? ""
    let confirm = args["confirm"] as? Bool ?? true
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    guard let parsed = formatter.date(from: text),
          let date = Calendar(identifier: .gregorian).date(byAdding: .hour, value: 12, to: parsed)
    else {
        throw YamlTestFailure("pickDate: not a YYYY-MM-DD date", actual: text, line: world.step.line)
    }
    // The date field shows its placeholder (or the date picked so far): the
    // date questions' placeholders of the survey on screen name it.
    let placeholders = Set(sdk.surveyOrchestrator.state?.config.canvasSurvey?.scenesByBlockId.values.compactMap { scene -> String? in
        if case .field(let input)? = scene.input, input.type == .date { return input.placeholder }
        return nil
    } ?? [])
    guard !placeholders.isEmpty else {
        throw YamlTestFailure("pickDate: no date question in the survey on screen", line: world.step.line)
    }
    try await tapSettled(world, window, what: "a date field", exactlyOne: false) {
        guard let shown = YamlWorld.shownText(of: $0) else { return false }
        return placeholders.contains(shown) || shown.range(of: #"^\d{4}-\d{2}-\d{2}$|/ "#, options: .regularExpression) != nil
    }
    var picker: UIDatePicker?
    do {
        try await world.waitUntil("the date picker", timeout: 5) {
            picker = YamlWorld.find(in: window) { $0 is UIDatePicker } as? UIDatePicker
            return picker != nil
        }
    } catch {
        throw YamlTestFailure("pickDate: no date picker opened", line: world.step.line)
    }
    picker?.setDate(date, animated: false)
    picker?.sendActions(for: .valueChanged)
    ComponentTestHost.drainRunLoop(for: 0.05)
    let button = confirm ? "Done" : "Cancel"
    try await tapSettled(world, window, what: "the picker's \(button)", exactlyOne: false) {
        YamlWorld.shownText(of: $0) == button && YamlWorld.isInsideAlert($0)
    }
    await world.settle()
}

/// Opens the one date field's picker without choosing, checks the day it
/// opened on and the range it allows, then closes it with Cancel.
@MainActor private func assertDatePicker(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let sdk = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure("nothing to tap", expected: "launchApp before this command",
                              line: world.step.line)
    }
    func iso(_ text: Any?, what: String) throws -> Date? {
        guard let text = text as? String else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: text),
              text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw YamlTestFailure("assertDatePicker: not a date",
                                  expected: "YYYY-MM-DD for \(what)", actual: text, line: world.step.line)
        }
        return Calendar(identifier: .gregorian).date(byAdding: .hour, value: 12, to: parsed)
    }
    let wantDate = try iso(args["date"], what: "date")
    let wantMin = try iso(args["min"], what: "min")
    let wantMax = try iso(args["max"], what: "max")
    guard wantDate != nil || wantMin != nil || wantMax != nil else {
        throw YamlTestFailure("nothing to check",
                              expected: "assertDatePicker with at least one of date, min, max",
                              actual: "\(args)", line: world.step.line)
    }
    let placeholders = Set(sdk.surveyOrchestrator.state?.config.canvasSurvey?.scenesByBlockId.values.compactMap { scene -> String? in
        if case .field(let input)? = scene.input, input.type == .date { return input.placeholder }
        return nil
    } ?? [])
    guard !placeholders.isEmpty else {
        throw YamlTestFailure("assertDatePicker: no date question in the survey on screen", line: world.step.line)
    }
    try await tapSettled(world, window, what: "a date field", exactlyOne: false) {
        guard let shown = YamlWorld.shownText(of: $0) else { return false }
        return placeholders.contains(shown) || shown.range(of: #"^\d{4}-\d{2}-\d{2}$|/ "#, options: .regularExpression) != nil
    }
    var picker: UIDatePicker?
    do {
        try await world.waitUntil("the date picker", timeout: 5) {
            picker = YamlWorld.find(in: window) { $0 is UIDatePicker } as? UIDatePicker
            return picker != nil
        }
    } catch {
        throw YamlTestFailure("assertDatePicker: no date picker opened", line: world.step.line)
    }
    guard let picker else {
        throw YamlTestFailure("assertDatePicker: no date picker opened", line: world.step.line)
    }
    func day(_ date: Date?) -> String? {
        guard let date else { return nil }
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    func check(_ what: String, want: Date?, got: Date?) throws {
        guard let want else { return }
        if day(want) != day(got) {
            throw YamlTestFailure("the picker \(what) is not as authored",
                                  expected: day(want), actual: day(got), line: world.step.line)
        }
    }
    try check("opened on", want: wantDate, got: picker.date)
    try check("starts at", want: wantMin, got: picker.minimumDate)
    try check("ends at", want: wantMax, got: picker.maximumDate)
    try await tapSettled(world, window, what: "the picker's Cancel", exactlyOne: false) {
        YamlWorld.shownText(of: $0) == "Cancel" && YamlWorld.isInsideAlert($0)
    }
    await world.settle()
}

extension YamlWorld {
    /// Whether [object] belongs to a presented alert (the date picker's).
    static func isInsideAlert(_ object: NSObject) -> Bool {
        var view: UIView? = (object as? UIView)
            ?? ((object as? UIAccessibilityElement)?.accessibilityContainer as? UIView)
        var hops = 0
        while let current = view, hops < 40 {
            if String(describing: type(of: current)).contains("Alert") { return true }
            view = current.superview
            hops += 1
        }
        return false
    }
}
