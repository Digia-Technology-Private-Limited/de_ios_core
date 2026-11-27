import Foundation
import UIKit
@testable import DigiaEngage

/// Scroll and transparency commands for exposure tests: a below-fold slot
/// starts unexposed until scrolled into view, and a transparent host hides
/// its slots without unmounting them. Mirrors the Flutter/Android drivers.
let yamlExposureHandlers: [String: YamlHandler] = [
    "mountSlotBelowFold": { world, args in try await mountBelowFold(world, "slot", args["key"] as? String ?? "") },
    "mountAnchorBelowFold": { world, args in try await mountBelowFold(world, "anchor", args["key"] as? String ?? "") },
    "scrollSlotIntoView": { world, args in try await scrollSlotIntoView(world, args["key"] as? String ?? "") },
    "scrollHostToTop": { world, _ in await scrollHostToTop(world) },
    "setHostTransparent": { world, args in try await setHostTransparent(world, args) },
]

@MainActor private func mountBelowFold(_ world: YamlWorld, _ kind: String, _ key: String) async throws {
    _ = try world.sdk
    let command = "mount\(kind.capitalized)BelowFold"
    guard !key.isEmpty else {
        throw YamlTestFailure("\(command) needs a key",
            expected: "\(command): <\(kind) key>",
            line: world.step.line)
    }
    let item = YamlHostMounts.Item(kind: kind, key: key)
    if world.mounts.belowFold.contains(item) || world.mounts.items.contains(item) {
        throw YamlTestFailure("a \(kind) \"\(key)\" is already mounted",
            expected: "unmount it first",
            line: world.step.line)
    }
    world.mounts.belowFold.append(item)
    await settleExposure(world)
}

/// Exposure is polled (`ExposureMonitor.interval`, 250 ms), not pushed: let
/// the polls after the scroll run, so the slot's appearance has been judged.
@MainActor private func settleExposure(_ world: YamlWorld) async {
    await world.settle()
    ExposureMonitor.shared.check()
    // Let StoryViewportUIView's KVO + 100ms scroll-settle debounce + SwiftUI update settle.
    ComponentTestHost.drainRunLoop(for: 0.22)
    await world.settle()
}

@MainActor private func yamlScrollView(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView {
        // The SDK's own scroll views (carousels) are nested inside the slot;
        // the host scroll view is the outermost one.
        return scroll
    }
    for sub in view.subviews {
        if let found = yamlScrollView(in: sub) {
            return found
        }
    }
    return nil
}

@MainActor private func scrollSlotIntoView(_ world: YamlWorld, _ key: String) async throws {
    _ = try world.sdk
    let item = YamlHostMounts.Item(kind: "slot", key: key)
    guard world.mounts.belowFold.contains(item) || world.mounts.items.contains(item) else {
        throw YamlTestFailure("no slot \"\(key)\" is mounted",
            expected: "a mountSlot before this step",
            line: world.step.line)
    }
    // A slot on the plain (non-scrolling) host is already in view.
    guard let window = world.window, let scroll = yamlScrollView(in: window) else {
        await world.settle()
        return
    }
    scroll.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
    await settleExposure(world)
}

@MainActor private func scrollHostToTop(_ world: YamlWorld) async {
    if let window = world.window, let scroll = yamlScrollView(in: window) {
        scroll.setContentOffset(.zero, animated: false)
    }
    await settleExposure(world)
}

@MainActor private func setHostTransparent(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let transparent = args["transparent"] as? Bool else {
        throw YamlTestFailure("setHostTransparent needs transparent",
            expected: "setHostTransparent: { transparent: true }",
            line: world.step.line)
    }
    world.mounts.transparent = transparent
    await world.settle()
    // Fading moves no frame, so nothing re-checks exposure on its own (the
    // harness nudges its scroll view for the same reason). Force a layout
    // pass over the whole window so every slot re-judges its exposure, then
    // nudge the host scroll view when there is one.
    if let window = world.window {
        markNeedsLayout(window)
        window.layoutIfNeeded()
        if let scroll = yamlScrollView(in: window) {
            let base = scroll.contentOffset
            scroll.setContentOffset(CGPoint(x: 0, y: base.y + 2), animated: false)
            ExposureMonitor.shared.check()
            scroll.setContentOffset(base, animated: false)
        }
    }
    await settleExposure(world)
}

@MainActor private func markNeedsLayout(_ view: UIView) {
    view.setNeedsLayout()
    for sub in view.subviews {
        markNeedsLayout(sub)
    }
}
