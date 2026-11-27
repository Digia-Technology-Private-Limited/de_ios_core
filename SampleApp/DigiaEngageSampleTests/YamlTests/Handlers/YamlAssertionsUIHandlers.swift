import Foundation
import UIKit
@testable import DigiaEngage

/// Asserting on what the real `DigiaHost` shows.
/// Mirrors `handlers/assertions_ui.dart`.
let yamlUiAssertionHandlers: [String: YamlHandler] = [
    "assertVisible": { try await assertShown($0, $1, visible: true) },
    "assertNotVisible": { try await assertShown($0, $1, visible: false) },
]

@MainActor private func assertShown(
    _ world: YamlWorld, _ args: [String: Any], visible: Bool
) async throws {
    if args.isEmpty {
        throw YamlTestFailure(
            "needs at least one of text, campaign, contains",
            line: world.step.line)
    }
    _ = try world.sdk
    let text = args["text"] as? String
    let campaign = args["campaign"] as? String
    let contains = args["contains"] as? String
    let wanted = [
        text.map { "text: \($0)" },
        campaign.map { "campaign: \($0)" },
        contains.map { "contains: \($0)" },
    ].compactMap { $0 }.joined(separator: ", ")

    func shown() -> Bool {
        let campaignShown = campaign.map { world.isDisplaying(campaign: $0) } ?? true
        let textShown = text.map { world.isShowing($0) } ?? true
        let containsShown = contains.map { world.isShowing($0) } ?? true
        return campaignShown && textShown && containsShown
    }

    if visible {
        // Delivery and rendering are asynchronous; wait for what should show.
        do {
            try await world.waitUntil("\"\(wanted)\" visible", timeout: 2.5) { shown() }
        } catch {
            throw YamlTestFailure(
                "nothing visible matches",
                expected: "visible match for {\(wanted)}",
                actual: "still not visible after 2.5s; texts on screen: \(world.visibleTexts)"
                    + (campaign.map { world.whyNotDisplaying($0) } ?? ""),
                line: world.step.line)
        }
    } else {
        // Absence is a snapshot: settle, then check. If an exiting SwiftUI
        // transition or UIKit UITextView link recognizer (~0.35s delay) is
        // still finishing, give it up to 0.75s before failing.
        await world.settle()
        if shown() {
            let deadline = Date().addingTimeInterval(0.75)
            while shown() && Date() < deadline {
                ComponentTestHost.drainRunLoop(for: 0.05)
                await Task.yield()
            }
        }
        if shown() {
            throw YamlTestFailure(
                "something visible matches",
                expected: "no visible match for {\(wanted)}",
                actual: "texts on screen: \(world.visibleTexts)",
                line: world.step.line)
        }
    }
}

extension YamlWorld {
    /// For a failure message: the campaign's deliveries and what the SDK
    /// logged about it.
    func whyNotDisplaying(_ key: String) -> String {
        let deliveries = cep.deliveries.filter { $0.trigger.campaignKey == key }.map {
            "\($0.presentation.state.value) \($0.presentation.outcome.settledValue.map { "\($0)" } ?? "")"
        }
        let records = logSink.records.filter { $0.campaignKey == key }.suffix(8).map {
            "\($0.reason?.wire ?? "-")\($0.extras.isEmpty ? "" : " \($0.extras)")"
        }
        return "; deliveries of \(key): \(deliveries); its last records: \(records)"
    }

    /// Whether [campaign] is displaying, whoever fired it: a CEP delivery,
    /// the overlay the SDK presents (a CEP, triggerCampaign or rule firing),
    /// a PiP the orchestrator still holds, or the content of a mounted slot.
    /// Mirrors `_displaying`.
    func isDisplaying(campaign key: String) -> Bool {
        // A delivery counts while it is displaying and not yet settled: a
        // dropped delivery never displays, even though its presentation exists.
        if cep.deliveries.contains(where: {
            $0.trigger.campaignKey == key && $0.presentation.state == .displaying && $0.presentation.outcome.settledValue == nil
        }) {
            return true
        }
        let sdk = SDKInstance.shared
        if sdk.controller.activeNudge?.payload.campaignKey == key { return true }
        // A PiP whose media could not be had is dropped and the orchestrator
        // lets it go, so presence here is the shown/not-shown distinction.
        // What the window drew stays in the harness pixel tests. Closing
        // (exit animation) counts as gone.
        if sdk.floaterOrchestrator.isShowing && sdk.floaterOrchestrator.state?.campaign.campaignKey == key { return true }
        // A story floater the orchestrator still holds.
        if sdk.floaterStoryOrchestrator.isShowing && sdk.floaterStoryOrchestrator.state?.campaign.campaignKey == key { return true }
        // A survey counts once its start delay passed (its presentation is
        // displaying), until it is dismissed, whoever fired it.
        if let survey = sdk.surveyOrchestrator.state, survey.payload.campaignKey == key,
           sdk.coordinator.ownerOf(survey.payload)?.state == .displaying
        {
            return true
        }
        return sdk.inlineController.slotOccupants.contains {
            $0.payload.campaignKey == key && mounts.slotMounted($0.slot)
        }
    }

    /// Whether [text] is on screen: in a visible text view or label, or read
    /// out by an accessibility element. Mirrors `SdkHarness.isShowing`.
    func isShowing(_ text: String) -> Bool {
        guard let window else { return false }
        return Self.find(in: window) { Self.shownText(of: $0)?.contains(text) == true } != nil
    }

    /// Every text on screen, for failure output.
    var visibleTexts: [String] {
        guard let window else { return [] }
        return collectTexts(in: window)
    }

    private func collectTexts(in root: NSObject, depth: Int = 0) -> [String] {
        guard depth < 60 else { return [] }
        var out: [String] = []
        if let view = root as? UIView, view.isHidden || view.alpha <= 0.01 {
            return out
        }
        if let text = Self.shownText(of: root) {
            out.append(text)
        }
        // A UIDatePicker's wheel exposes 10,000 year rows as accessibility elements.
        if root is UIDatePicker { return out }
        if let view = root as? UIView {
            for subview in view.subviews {
                out += collectTexts(in: subview, depth: depth + 1)
            }
        }
        if let elements = root.accessibilityElements {
            for case let element as NSObject in elements {
                out += collectTexts(in: element, depth: depth + 1)
            }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = root.accessibilityElement(at: index) as? NSObject {
                        out += collectTexts(in: element, depth: depth + 1)
                    }
                }
            }
        }
        return out
    }

    static func shownText(of object: NSObject) -> String? {
        (object as? UITextView)?.text ?? (object as? UILabel)?.text
            ?? object.accessibilityLabel ?? object.accessibilityValue
    }

    static func identifier(of object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    /// Every visible element matching, one per on-screen frame (a SwiftUI
    /// control and the accessibility element wrapping it count once).
    static func findAll(in root: NSObject, where match: (NSObject) -> Bool) -> [NSObject] {
        var out: [NSObject] = []
        var frames: [CGRect] = []
        collect(in: root, depth: 0, where: match) { found in
            let frame = found.accessibilityFrame
            guard !frame.isEmpty, !frames.contains(where: { $0.contains(frame) || frame.contains($0) })
            else { return }
            frames.append(frame)
            out.append(found)
        }
        return out
    }

    private static func collect(
        in root: NSObject, depth: Int, where match: (NSObject) -> Bool, _ add: (NSObject) -> Void
    ) {
        guard depth < 60 else { return }
        if let view = root as? UIView {
            guard !view.isHidden, view.alpha > 0.01 else { return }
        }
        if match(root) { add(root) }
        if root is UIDatePicker { return }
        if let view = root as? UIView {
            for subview in view.subviews { collect(in: subview, depth: depth + 1, where: match, add) }
        }
        if let elements = root.accessibilityElements {
            for case let element as NSObject in elements {
                collect(in: element, depth: depth + 1, where: match, add)
            }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = root.accessibilityElement(at: index) as? NSObject {
                        collect(in: element, depth: depth + 1, where: match, add)
                    }
                }
            }
        }
    }

    static func find(
        in root: NSObject, depth: Int = 0, where match: (NSObject) -> Bool
    ) -> NSObject? {
        guard depth < 60 else { return nil }
        if let view = root as? UIView {
            // Only what a user could see: hidden or transparent views and
            // their subtrees don't count.
            guard !view.isHidden, view.alpha > 0.01 else { return nil }
        }
        if match(root) { return root }
        if root is UIDatePicker { return nil }
        if let view = root as? UIView {
            for subview in view.subviews {
                if let found = find(in: subview, depth: depth + 1, where: match) {
                    return found
                }
            }
        }
        if let elements = root.accessibilityElements {
            for case let element as NSObject in elements {
                if let found = find(in: element, depth: depth + 1, where: match) {
                    return found
                }
            }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = root.accessibilityElement(at: index) as? NSObject,
                       let found = find(in: element, depth: depth + 1, where: match)
                    {
                        return found
                    }
                }
            }
        }
        return nil
    }
}
