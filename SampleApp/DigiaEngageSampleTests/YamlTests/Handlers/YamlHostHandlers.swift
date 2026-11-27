import Foundation
@testable import DigiaEngage

/// The host screen's own views (slots and anchors the test mounts), plus
/// commands that drive the host app rather than the SDK's public calls.
/// Mirrors `handlers/host.dart`.
let yamlHostHandlers: [String: YamlHandler] = [
    "mountSlot": { try await mount($0, "slot", $1["key"] as? String ?? "") },
    "unmountSlot": { try await unmount($0, "slot", $1["key"] as? String ?? "") },
    "mountAnchor": { try await mount($0, "anchor", $1["key"] as? String ?? "") },
    "unmountAnchor": { try await unmount($0, "anchor", $1["key"] as? String ?? "") },
    "tapSlot": { try await tapSlot($0, $1["key"] as? String ?? "", index: $1["index"] as? Int ?? 0) },
    "tapSlotCenter": { try await tapSlotCenter($0, $1["key"] as? String ?? "") },
    "swipeSlot": { try await swipeSlot($0, $1) },
    "holdSlot": { try await holdSlot($0, $1) },
    "repeat": repeatSteps,
    "triggerCampaign": { world, args in
        let key = args["campaignKey"] as? String ?? ""
        // Before launch (or after stopApp) there is no process yet: like any
        // host-app call, it runs at the next launch before initialize, when
        // core drops it as not_initialized.
        if !world.launched {
            world.preLaunch.append { _ = Digia.triggerCampaign(key) }
            return
        }
        _ = try world.sdk
        _ = Digia.triggerCampaign(key)
    },
]

@MainActor private func mount(_ world: YamlWorld, _ kind: String, _ key: String) async throws {
    let item = YamlHostMounts.Item(kind: kind, key: key)
    if world.mounts.items.contains(item) || world.mounts.belowFold.contains(item) {
        throw YamlTestFailure(
            "a \(kind) \"\(key)\" is already mounted",
            expected: "unmount it first",
            line: world.step.line)
    }
    world.mounts.items.append(item)
    await settleExposure(world)
}

/// Exposure is polled (`ExposureMonitor.interval`, 250 ms), not pushed: lets
/// the poll after the layout run, so the view's appearance has been judged.
@MainActor private func settleExposure(_ world: YamlWorld) async {
    await world.settle()
    ExposureMonitor.shared.check()
    await world.settle()
}

@MainActor private func unmount(_ world: YamlWorld, _ kind: String, _ key: String) async throws {
    let item = YamlHostMounts.Item(kind: kind, key: key)
    if world.mounts.belowFold.contains(item) {
        world.mounts.belowFold.removeAll { $0 == item }
        await settleExposure(world)
        return
    }
    guard world.mounts.items.contains(item) else {
        throw YamlTestFailure(
            "no \(kind) \"\(key)\" is mounted",
            expected: "a mount\(kind) before this step",
            line: world.step.line)
    }
    world.mounts.items.removeAll { $0 == item }
    await settleExposure(world)
}

/// A real tap near the mounted slot's top-left (40 points in), the way a
/// finger tapping its first content would (a story strip's first card, which
/// opens the viewer at the first item). With index, the index-th card of a
/// story strip, laid out from the parsed card config like the hand-written
/// card taps.
@MainActor private func tapSlot(_ world: YamlWorld, _ key: String, index: Int = 0) async throws {
    _ = try world.sdk
    guard !key.isEmpty, world.mounts.slotMounted(key) else {
        throw YamlTestFailure(
            "no slot \"\(key)\" is mounted",
            expected: "a mountSlot before this step",
            line: world.step.line)
    }
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    var last: CGRect?
    var steadyReads = 0
    do {
        try await world.waitUntil("slot \"\(key)\" settled on screen", timeout: 8) {
            guard let frame = YamlWorld.find(in: window, where: { YamlWorld.identifier(of: $0) == "slot:\(key)" })?.accessibilityFrame,
                  !frame.isEmpty
            else {
                return false
            }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 3
        }
    } catch {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "a settled slot \"\(key)\" on screen",
            actual: "no match after 8s; texts on screen: \(world.visibleTexts)",
            line: world.step.line)
    }
    guard let frame = last else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "a settled slot \"\(key)\" on screen",
            actual: "no match",
            line: world.step.line)
    }
    let frameInWindow = window.convert(frame, from: window.screen.coordinateSpace)
    if index == 0 {
        try TouchSynthesizer.tap(
            at: CGPoint(x: frameInWindow.minX + 40, y: frameInWindow.minY + 40), in: window)
    } else {
        // The index-th card, laid out from the parsed card config the way the
        // hand-written card taps compute it.
        guard let config = SDKInstance.shared.inlineController.getStoryConfig(key) else {
            throw YamlTestFailure(
                "no story in slot \"\(key)\"",
                expected: "a story strip with more than \(index) cards",
                actual: "no story config",
                line: world.step.line)
        }
        let width = config.card.width
        let spacing = Double(config.card.spacing)
        try TouchSynthesizer.tap(
            at: CGPoint(
                x: frameInWindow.minX + spacing + Double(index) * (width + spacing) + width / 2,
                y: frameInWindow.midY),
            in: window)
    }
    if SDKInstance.shared.inlineController.getStoryConfig(key) != nil {
        // A story card opens the full-screen viewer: give it a beat to be
        // presented (and its cross-dissolve to finish, so the next touch
        // reaches the viewer rather than the page under it). Other slots
        // carry on without waiting; the following assertStoryViewer is the
        // gatekeeper.
        let deadline = Date().addingTimeInterval(3)
        while presentedStoryViewer(world) == nil, Date() <= deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if presentedStoryViewer(world) != nil {
            TouchSynthesizer.drainRunLoop(for: 0.05)
        }
    }
}

/// A real tap at the centre of the mounted slot's frame, as a user tapping
/// the middle of its content would (a carousel's shown slide, which fills the
/// slot's middle but need not reach its top-left corner).
@MainActor private func tapSlotCenter(_ world: YamlWorld, _ key: String) async throws {
    _ = try world.sdk
    guard !key.isEmpty, world.mounts.slotMounted(key) else {
        throw YamlTestFailure(
            "no slot \"\(key)\" is mounted",
            expected: "a mountSlot before this step",
            line: world.step.line)
    }
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    var last: CGRect?
    var steadyReads = 0
    do {
        try await world.waitUntil("slot \"\(key)\" settled on screen", timeout: 8) {
            guard let frame = YamlWorld.find(in: window, where: { YamlWorld.identifier(of: $0) == "slot:\(key)" })?.accessibilityFrame,
                  !frame.isEmpty
            else {
                return false
            }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 3
        }
    } catch {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "a settled slot \"\(key)\" on screen",
            actual: "no match after 8s; texts on screen: \(world.visibleTexts)",
            line: world.step.line)
    }
    guard let frame = last else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "a settled slot \"\(key)\" on screen",
            actual: "no match",
            line: world.step.line)
    }
    let frameInWindow = window.convert(frame, from: window.screen.coordinateSpace)
    try TouchSynthesizer.tap(
        at: CGPoint(x: frameInWindow.midX, y: frameInWindow.midY), in: window)
}

/// A real drag across the middle of the mounted slot's frame, as a user
/// swiping its content would: centred (harness geometry, mid ± distance/2,
/// both ends on-screen) and 240 pt like the harness's proven flick, so the
/// page turns promptly. A fling, not a slow drag: the carousel turns the
/// page on velocity, and an off-screen end starves it.
@MainActor private func swipeSlot(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    let key = args["key"] as? String ?? ""
    guard !key.isEmpty, world.mounts.slotMounted(key) else {
        throw YamlTestFailure(
            "no slot \"\(key)\" is mounted",
            expected: "a mountSlot before this step",
            line: world.step.line)
    }
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to swipe",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    guard let direction = args["direction"] as? String,
          ["up", "down", "left", "right"].contains(direction) else {
        throw YamlTestFailure(
            "bad swipe direction",
            expected: "up, down, left or right",
            actual: "\(args["direction"] ?? "none")",
            line: world.step.line)
    }
    // The harness's flick (dx=240): fast enough to turn the page, slow
    // enough to settle inside the YAML waitForAnimation drain. A 300 pt
    // fling at 0.2 s releases at ~1500 pt/s and its deceleration + snap
    // outlasts swipeSlot's settle plus the 1.0 s drain, so Step Viewed
    // lands after assertEvents' flush.
    let distance = (args["distance"] as? NSNumber)?.doubleValue ?? 240
    let translation: CGVector = switch direction {
    case "down": CGVector(dx: 0, dy: distance)
    case "up": CGVector(dx: 0, dy: -distance)
    case "left": CGVector(dx: -distance, dy: 0)
    default: CGVector(dx: distance, dy: 0)
    }
    var last: CGRect?
    var steadyReads = 0
    do {
        try await world.waitUntil("slot \"\(key)\" settled on screen", timeout: 8) {
            guard let frame = YamlWorld.find(in: window, where: { YamlWorld.identifier(of: $0) == "slot:\(key)" })?.accessibilityFrame,
                  !frame.isEmpty
            else {
                return false
            }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 3
        }
    } catch {
        throw YamlTestFailure(
            "nothing to swipe",
            expected: "a settled slot \"\(key)\" on screen",
            actual: "no match after 8s; texts on screen: \(world.visibleTexts)",
            line: world.step.line)
    }
    guard let frame = last else {
        throw YamlTestFailure(
            "nothing to swipe",
            expected: "a settled slot \"\(key)\" on screen",
            actual: "no match",
            line: world.step.line)
    }
    let frameInWindow = window.convert(frame, from: window.screen.coordinateSpace)
    // Centred on the slot's middle, like the harness's swipeCarousel
    // (centre ± dx/2): both start and end stay on-screen, so the fling
    // keeps the velocity that turns the page.
    let start = switch direction {
    case "down": CGPoint(x: frameInWindow.midX, y: frameInWindow.midY - distance / 2)
    case "up": CGPoint(x: frameInWindow.midX, y: frameInWindow.midY + distance / 2)
    case "left": CGPoint(x: frameInWindow.midX + distance / 2, y: frameInWindow.midY)
    default: CGPoint(x: frameInWindow.midX - distance / 2, y: frameInWindow.midY)
    }
    try TouchSynthesizer.drag(
        from: start,
        by: translation, in: window, duration: 0.2)
    ComponentTestHost.drainRunLoop(for: 0.35)
    await world.settle()
}

/// A finger pressing down near the mounted slot's top-left (40 points in) and
/// resting there for `for`, then lifting: an autoplay carousel holds its
/// advance while the finger rests and resumes after it lifts. The hold burns
/// real time, which is also what the carousel's own timer counts on.
@MainActor private func holdSlot(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    let key = args["key"] as? String ?? ""
    guard !key.isEmpty, world.mounts.slotMounted(key) else {
        throw YamlTestFailure(
            "no slot \"\(key)\" is mounted",
            expected: "a mountSlot before this step",
            line: world.step.line)
    }
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to hold",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    var last: CGRect?
    var steadyReads = 0
    do {
        try await world.waitUntil("slot \"\(key)\" settled on screen", timeout: 8) {
            guard let frame = YamlWorld.find(in: window, where: { YamlWorld.identifier(of: $0) == "slot:\(key)" })?.accessibilityFrame,
                  !frame.isEmpty
            else {
                return false
            }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 3
        }
    } catch {
        throw YamlTestFailure(
            "nothing to hold",
            expected: "a settled slot \"\(key)\" on screen",
            actual: "no match after 8s; texts on screen: \(world.visibleTexts)",
            line: world.step.line)
    }
    guard let frame = last else {
        throw YamlTestFailure(
            "nothing to hold",
            expected: "a settled slot \"\(key)\" on screen",
            actual: "no match",
            line: world.step.line)
    }
    let frameInWindow = window.convert(frame, from: window.screen.coordinateSpace)
    let seconds = Double((args["for"] as? YamlDuration)?.milliseconds ?? 0) / 1000.0
    try TouchSynthesizer.press(
        at: CGPoint(x: frameInWindow.midX, y: frameInWindow.midY),
        in: window, for: seconds)
    await world.settle()
}

/// Runs `commands` `times` times, each step as at the top level.
@MainActor private func repeatSteps(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let times = args["times"] as? Int ?? 0
    let outer = world.step!
    let steps: [YamlStep] = try (args["commands"] as? [Any] ?? []).map { command in
        if let name = command as? String {
            return YamlStep(name: name, rawArg: nil, line: outer.line, written: name)
        }
        if let map = command as? [String: Any], map.count == 1, let (name, arg) = map.first {
            return YamlStep(
                name: name, rawArg: arg is NSNull ? nil : arg, line: outer.line,
                written: "\(name): \(arg)")
        }
        throw YamlTestFailure(
            "repeat: malformed command",
            expected: "a bare name or a one-key map",
            actual: "\(command)",
            line: outer.line)
    }
    let contract = try YamlDiscovery.contract()
    defer { world.step = outer }
    for round in 1...max(times, 1) where times > 0 {
        for step in steps {
            world.step = step
            do {
                let bound = try contract.bind(step)
                guard let handler = yamlAllHandlers[step.name] else {
                    throw YamlTestFailure("no handler registered for \"\(step.name)\"", line: outer.line)
                }
                try await handler(world, bound)
                await world.settle()
            } catch let failure as YamlTestFailure {
                throw YamlTestFailure(
                    "repeat round \(round), \(step.name): \(failure.message)",
                    expected: failure.expected, actual: failure.actual, line: outer.line)
            }
        }
    }
}
