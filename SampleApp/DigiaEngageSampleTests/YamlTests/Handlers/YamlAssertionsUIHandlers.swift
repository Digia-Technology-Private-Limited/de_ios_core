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
            "needs at least one of text, campaign",
            line: world.step.line)
    }
    _ = try world.sdk
    let text = args["text"] as? String
    let campaign = args["campaign"] as? String
    let wanted = [
        text.map { "text: \($0)" },
        campaign.map { "campaign: \($0)" },
    ].compactMap { $0 }.joined(separator: ", ")

    func shown() -> Bool {
        let campaignShown = campaign.map { key in
            world.cep.deliveries.contains { delivery in
                delivery.trigger.campaignKey == key
                    && delivery.presentation.state == .displaying
            }
        } ?? true
        let textShown = text.map { world.isShowing($0) } ?? true
        return campaignShown && textShown
    }

    if visible {
        // Delivery and rendering are asynchronous; wait for what should show.
        do {
            try await world.waitUntil("\"\(wanted)\" visible", timeout: 5) { shown() }
        } catch {
            throw YamlTestFailure(
                "nothing visible matches",
                expected: "visible match for {\(wanted)}",
                actual: "still not visible after 5s; texts on screen: \(world.visibleTexts)",
                line: world.step.line)
        }
    } else {
        // Absence is a snapshot: settle, then check once.
        await world.settle()
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
