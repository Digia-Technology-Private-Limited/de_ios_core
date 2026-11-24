import Foundation
import SwiftUI
import UIKit
@testable import DigiaEngage

/// Debug-only screens and the timeline buffer, and the debug-settings link.
/// Mirrors Flutter's `test/yaml/handlers/debug.dart`.
let yamlDebugHandlers: [String: YamlHandler] = [
    "openTimeline": { world, args in try await openTimeline(world, args) },
    "openDebugSettings": { world, _ in try await openDebugSettings(world) },
    "emitTimelineRecord": { world, args in try await emitTimelineRecord(world, args) },
    "openLink": { world, args in try await openLink(world, args) },
    "clearTimeline": { world, _ in ScreenSink.shared.clear() },
    "emitSse": { world, args in try await emitSse(world, args) },
    "tapSwitch": { world, args in try await tapSwitch(world, args) },
    "tapRow": { world, args in try await tapRow(world, args) },
    "assertAbove": { world, args in try await assertAbove(world, args) },
]

/// Opens the timeline over the running app, as the debug settings do:
/// presented over whatever is already presented (a nudge sheet, say).
@MainActor private func openTimeline(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to open over",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    var root = try requireRoot(window.rootViewController)
    while let presented = root.presentedViewController { root = presented }
    let screen = UIHostingController(rootView: NavigationView { DigiaCampaignTimelineView() })
    screen.modalPresentationStyle = .fullScreen
    root.present(screen, animated: false)
    try await world.waitUntil("the timeline is open", timeout: 5) { world.isShowing("Campaign timeline") }
    // The simulator's own top inset differs by model (a 17 Pro Max reports
    // more than the reference phone's 47), while every other golden lays out
    // against the fixed reference — pin this screen to it, so the header
    // starts at the same y as Flutter (SafeArea) and Android (Scaffold).
    // Only once the presented view is on screen and laid out: pinning
    // earlier reads a zero inset and adds 47 on top of the real one.
    screen.view.layoutIfNeeded()
    GoldenScreen.pinSafeArea(of: screen)
    screen.view.layoutIfNeeded()
    await world.settle()
}

/// Opens the debug settings through the production presenter (the same one
/// the bubble and the deeplink use), so its guards run too.
@MainActor private func openDebugSettings(_ world: YamlWorld) async throws {
    _ = try world.sdk
    guard let window = world.window,
          let root = window.rootViewController
    else {
        throw YamlTestFailure(
            "nothing to open over",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    Digia.presentDebugSettings(from: root)
    try await world.waitUntil("the debug settings are open", timeout: 5) { world.isShowing("Digia bubble") }
    ComponentTestHost.drainRunLoop(for: 0.05)
    await world.settle()
}

/// A reason symbol from a version of the SDK this screen predates.
private struct YamlFutureReason: DiagnosticReason {
    let wire: String
}

/// Puts one record straight into the on-device buffer, for rows no fixture
/// can produce. `at` is a local "HH:MM:SS" stamped on the record (the clock
/// row needs single digits on purpose); without it the record keeps the
/// harness's fixed timestamp.
@MainActor private func emitTimelineRecord(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let reason = args["reason"] as? String
    let message = args["message"] as? String
    guard reason != nil || message != nil else {
        throw YamlTestFailure(
            "emitTimelineRecord records nothing",
            expected: "at least one of reason, message",
            line: world.step.line)
    }
    var at = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5))!
    if let clock = args["at"] as? String {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else {
            throw YamlTestFailure(
                "emitTimelineRecord: bad at",
                expected: "\"HH:MM:SS\"",
                actual: clock,
                line: world.step.line)
        }
        at = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 2,
                                                        hour: parts[0], minute: parts[1], second: parts[2]))!
    }
    let dot: DigiaLogSeverity = try severity(of: args["severity"], line: world.step.line)
    ScreenSink.shared.emit(TimelineRecord(
        timestamp: at,
        severity: dot,
        tag: "DIGIA", message: message ?? "developer sentence",
        stage: .gating, reason: reason.map(YamlFutureReason.init(wire:)), campaignKey: "yaml"))
}

/// The dot colour an `emitTimelineRecord severity` asks for.
private func severity(of raw: Any?, line: Int) throws -> DigiaLogSeverity {
    switch raw as? String {
        case nil, "debug": return .debug
        case "info": return .info
        case "warn": return .warn
        case "error": return .error
        default:
            throw YamlTestFailure(
                "emitTimelineRecord: bad severity",
                expected: "debug, info, warn or error",
                line: line)
    }
}

/// Delivers one dashboard event down every open live-test stream. Failing
/// when none is open proves switching live testing on opened the stream.
@MainActor private func emitSse(_ world: YamlWorld, _ args: [String: Any]) async throws {    guard let event = args["event"] as? String else {
        throw YamlTestFailure(
            "emitSse: no event",
            expected: "event like connected or error",
            line: world.step.line)
    }
    let data: String
    if let raw = args["data"] {
        if let text = raw as? String {
            data = text
        } else if JSONSerialization.isValidJSONObject(raw),
                  let json = try? JSONSerialization.data(withJSONObject: raw),
                  let text = String(data: json, encoding: .utf8)
        {
            data = text
        } else {
            throw YamlTestFailure(
                "emitSse: data is not JSON",
                expected: "a map like { deviceId: d }",
                line: world.step.line)
        }
    } else {
        data = "{}"
    }
    try world.network.emitSse(event: event, data: data, line: world.step.line)
    await world.settle()
}

/// Hands the link to the SDK the way the OS would. A debug link opens the/// settings; any other link is left to the host app. Before launch the
/// request waits for the next launch, as a host delivering its launch URL
/// once the shell is up — where it lands is stack-defined (the next launch
/// routes it on iOS, the engine's initial route on Flutter, the Activity
/// entry on Android).
@MainActor private func openLink(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let urlString = args["url"] as? String,
          let url = URL(string: urlString)
    else {
        throw YamlTestFailure(
            "openLink: bad url",
            expected: "a URL string",
            actual: "\(args["url"] as Any)",
            line: world.step.line)
    }
    guard Digia.isDebugSettingsDeepLink(url) else { return }
    guard world.launched, let window = world.window,
          let root = window.rootViewController
    else {
        // Cold: the host delivers its launch URL once the shell — and the
        // SDK — are up; the next launch routes it.
        world.pendingDebugLink = urlString
        return
    }
    _ = Digia.handleDeepLink(url, from: root)
    try await world.waitUntil("the debug settings are open", timeout: 5) { world.isShowing("Digia bubble") }
    await world.settle()
}

/// A real touch on the switch of the row titled `row`, flipping the setting
/// without opening the row's sub-screen. A SwiftUI `Toggle` reads out "0" or
/// "1": the switch level with the title, to its right.
@MainActor private func tapSwitch(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    guard let row = args["row"] as? String else {
        throw YamlTestFailure(
            "tapSwitch: no row",
            expected: "tapSwitch: { row: ... }",
            actual: "\(args)",
            line: world.step.line)
    }
    func switchFrame() -> CGRect? {
        let switches = YamlWorld.findAll(in: window) { $0.accessibilityValue == "0" || $0.accessibilityValue == "1" }
            .map { $0.accessibilityFrame }
        // A pushed screen repeats a setting's row: later matches are on top.
        let rows = YamlWorld.findAll(in: window) {
            guard let text = YamlWorld.shownText(of: $0) else { return false }
            return text == row || text.hasPrefix(row + ", ")
        }.map { $0.accessibilityFrame }.reversed()
        var best: CGRect?
        var bestDy = CGFloat.greatestFiniteMagnitude
        for title in rows {
            for toggle in switches where toggle.midX > title.midX {
                let dy = abs(toggle.midY - title.midY)
                if dy < bestDy {
                    bestDy = dy
                    best = toggle
                }
            }
        }
        return best
    }
    var last: CGRect?
    var steadyReads = 0
    try await world.waitUntil("the \(row) switch settled on screen", timeout: 8) {
        guard let frame = switchFrame(), !frame.isEmpty else {
            steadyReads = 0
            last = nil
            return false
        }
        steadyReads = frame == last ? steadyReads + 1 : 0
        last = frame
        return steadyReads >= 3
    }
    try TouchSynthesizer.tap(at: CGPoint(x: last!.midX, y: last!.midY), in: window)
}

/// A real tap on the title line of the row titled `title`, at its leading
/// edge: a plain button row is hit only on its own text, not on the gap
/// beside a short subtitle. Mirrors the hosted harness's `widgetsTap(rowTitle:)`.
@MainActor private func tapRow(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    guard let title = args["title"] as? String else {
        throw YamlTestFailure(
            "tapRow: no title",
            expected: "tapRow: { title: ... }",
            actual: "\(args)",
            line: world.step.line)
    }
    func titleFrame() -> CGRect? {
        YamlWorld.findAll(in: window) {
            guard let text = YamlWorld.shownText(of: $0) else { return false }
            return text == title || text.hasPrefix(title + ", ")
        }.first?.accessibilityFrame
    }
    var last: CGRect?
    var steadyReads = 0
    try await world.waitUntil("the title of the \(title) row settled on screen", timeout: 8) {
        guard let frame = titleFrame(), !frame.isEmpty else {
            steadyReads = 0
            last = nil
            return false
        }
        steadyReads = frame == last ? steadyReads + 1 : 0
        last = frame
        return steadyReads >= 3
    }
    guard let row = last else {
        throw YamlTestFailure(
            "no \"\(title)\" row",
            expected: "the \"\(title)\" settings row on screen",
            line: world.step.line)
    }
    ComponentTestHost.drainRunLoop(for: 0.05)
    try TouchSynthesizer.tap(at: CGPoint(x: row.minX + 16, y: row.minY + 8), in: window)
    ComponentTestHost.drainRunLoop(for: 0.05)
}

/// The visible text `top` is drawn above `bottom`, as a reader checking that
/// a newer timeline card sits above an older one would. Each must match
/// exactly one element.
@MainActor private func assertAbove(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to order",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    guard let top = args["top"] as? String, let bottom = args["bottom"] as? String else {
        throw YamlTestFailure(
            "assertAbove: needs top and bottom",
            expected: "assertAbove: { top: ..., bottom: ... }",
            actual: "\(args)",
            line: world.step.line)
    }
    func center(of text: String, which: String) throws -> CGFloat {
        let matches = YamlWorld.findAll(in: window) { YamlWorld.shownText(of: $0) == text }
        guard matches.count == 1 else {
            throw YamlTestFailure(
                "\"\(which)\" matches \(matches.count) texts",
                expected: "exactly one visible \"\(which)\" to order by",
                actual: "\(matches.count) matches",
                line: world.step.line)
        }
        return matches[0].accessibilityFrame.midY
    }
    let topY = try center(of: top, which: "top \"\(top)\"")
    let bottomY = try center(of: bottom, which: "bottom \"\(bottom)\"")
    guard topY < bottomY else {
        throw YamlTestFailure(
            "\"\(top)\" is not above \"\(bottom)\"",
            expected: "\"\(top)\" drawn above \"\(bottom)\"",
            actual: "centres at \(topY) and \(bottomY)",
            line: world.step.line)
    }
}

@MainActor private func requireRoot(_ value: UIViewController?) throws -> UIViewController {
    guard let value else {
        throw YamlTestFailure("no root view controller", expected: "a booted host window")
    }
    return value
}
