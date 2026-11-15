import Foundation
import SnapshotTesting
import Testing
import UIKit
@testable import DigiaEngage

/// Interacting with what the real `DigiaHost` shows, and snapshots of it.
/// Mirrors `handlers/ui.dart`.
let yamlUiHandlers: [String: YamlHandler] = [
    "tapOn": tapOn,
    "back": unsupported(
        "iOS has no system back gesture: an iOS nudge never closes from back. " +
        "A file that needs it is iOS-specific by platform design."),
    "waitForAnimationToEnd": { world, _ in
        // As long as the hand-written goldens settle before snapshotting
        // (`drainRunLoop(for: 1.0)` there): the sheet slide-up outlasts a
        // short drain, and a mid-flight frame fails pixel-exact goldens.
        world.window?.layoutIfNeeded()
        ComponentTestHost.drainRunLoop(for: 1.0)
    },
    "takeScreenshot": takeScreenshot,
]

@MainActor private func tapOn(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let id = args["id"] as? String
    let text = args["text"] as? String
    let point = args["point"] as? String
    if [id, text, point].compactMap({ $0 }).count != 1 {
        throw YamlTestFailure(
            "needs exactly one of id, text, point",
            expected: #"tapOn: { id: ... } | { text: ... } | { point: "x%,y%" }"#,
            actual: "\(args)")
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
    } else {
        what = "text \"\(text!)\""
        matches = { YamlWorld.shownText(of: $0)?.contains(text!) == true }
    }
    // Wait for the element to stop moving first: a surface's entry animation
    // would otherwise send the touch to where the element *was*. The frame
    // must also hold for 400 ms, not just a few reads. Mirrors the hosted
    // harness's `tap(id:)`/`tap(text:)`.
    var last: CGRect?
    var steadyReads = 0
    do {
        try await world.waitUntil("an element with \(what) settled on screen", timeout: 8) {
            guard let frame = YamlWorld.find(in: window, where: matches)?.accessibilityFrame,
                  !frame.isEmpty
            else {
                return false
            }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 8
        }
    } catch {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "an element with \(what) on screen",
            actual: "no settled match after 8s",
            line: world.step.line)
    }
    guard let frame = last else {
        throw YamlTestFailure(
            "nothing to tap",
            expected: "an element with \(what) on screen",
            actual: "no match",
            line: world.step.line)
    }
    let pointInWindow = window.convert(frame, from: window.screen.coordinateSpace)
    try TouchSynthesizer.tap(
        at: CGPoint(x: pointInWindow.midX, y: pointInWindow.midY), in: window)
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
    guard world.onPhone, let window = world.window else {
        throw YamlTestFailure(
            "takeScreenshot needs launchApp with host: phone",
            expected: "the golden frame the baselines are drawn on",
            line: world.step.line)
    }
    let image = ComponentTestHost.settledImage(of: window)
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
    Attachment.record(image, named: "\(surface)-\(file)-actual", as: .png)
    Attachment.record(reference, named: "\(surface)-\(file)-reference", as: .png)
    if let (message, attachments) = diffing.diffV2(reference, image) {
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
