import Foundation
import Testing
import UIKit
@testable import DigiaEngage

/// Where an anchorless guide target lands on this device: `AnchorlessTarget.decode` and
/// `resolve(currentPageKey:window:)` over a phone-sized window with a notch and a home indicator.
///
/// The shared fixtures (`campaigns/anchorless/`) and their goldens only author `startFixed`,
/// `topFixed` and `stretch` rules, so the far-edge, centred, proportional and width-scaled rules —
/// and the reference container — are pinned here against the semantics of
/// `flutter/core/lib/src/anchorless/anchorless_geometry_rules.dart` (which has no unit test of its
/// own to port). Expected rects are worked by hand from a 390 × 844 window with a 47 pt top and a
/// 34 pt bottom inset, so app content is `(0, 47, 390, 763)`.
@Suite("Media floater: anchorless geometry", .tags(.unit, .guide))
@MainActor
struct MediaFloaterAnchorlessGeometryTests {

    /// A window whose safe area the test chooses.
    private final class InsetWindow: UIWindow {
        var insets = UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
        override var safeAreaInsets: UIEdgeInsets { insets }
    }

    private func window(insets: UIEdgeInsets? = nil) -> InsetWindow {
        let window = InsetWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        if let insets { window.insets = insets }
        return window
    }

    private func axis(_ frame: String, _ rule: [String: Any]) -> [String: Any] {
        ["frame": frame, "rule": rule]
    }

    private func target(
        horizontal: [String: Any], vertical: [String: Any],
        referenceContainer: [String: Any]? = nil
    ) -> AnchorlessTarget? {
        var json: [String: Any] = [
            "type": "anchorless", "version": 1, "pageKey": "home",
            "imageUrl": "https://cdn.example.com/crop.png",
            "horizontal": horizontal, "vertical": vertical,
        ]
        if let referenceContainer { json["referenceContainer"] = referenceContainer }
        return AnchorlessTarget.decode(try! JSONSerialization.data(withJSONObject: json))
    }

    private func resolve(_ target: AnchorlessTarget?, in window: UIWindow? = nil) throws -> Result<CGRect, AnchorlessFailure> {
        try #require(target, "the target did not decode").resolve(currentPageKey: "home", window: window ?? self.window())
    }

    struct RuleCase: CustomTestStringConvertible, Sendable {
        let name: String
        /// Axis placements as wire JSON.
        let horizontal: String
        let vertical: String
        let expected: CGRect
        var testDescription: String { name }
    }

    nonisolated static let rules: [RuleCase] = [
        // Fails if: anchorless_geometry.swift `.farFixed` `span = (extent - offset - size)...(extent - offset)`
        // -> `span = offset...(offset + size)`.
        RuleCase(
            name: "endFixed / bottomFixed measure from the far edges of app content",
            horizontal: #"{"frame": "appContent", "rule": {"kind": "endFixed", "endOffset": 16, "width": 100}}"#,
            vertical: #"{"frame": "appContent", "rule": {"kind": "bottomFixed", "bottomOffset": 20, "height": 50}}"#,
            expected: CGRect(x: 274, y: 740, width: 100, height: 50)),
        // Fails if: anchorless_geometry.swift `resolve` `appContent: CGRect(x: leftInset, y: topInset,`
        // -> `appContent: CGRect(x: 0, y: 0,` (the home indicator is not cleared).
        RuleCase(
            name: "bottomFixed against the window ignores the home indicator",
            horizontal: #"{"frame": "window", "rule": {"kind": "endFixed", "endOffset": 16, "width": 100}}"#,
            vertical: #"{"frame": "window", "rule": {"kind": "bottomFixed", "bottomOffset": 20, "height": 50}}"#,
            expected: CGRect(x: 274, y: 774, width: 100, height: 50)),
        // Fails if: anchorless_geometry.swift `.centered` `span = ((extent - size) / 2)...((extent + size) / 2)`
        // -> `span = 0...size`.
        RuleCase(
            name: "centered sits in the middle of app content, edges rounded to whole points",
            horizontal: #"{"frame": "appContent", "rule": {"kind": "centered", "width": 200}}"#,
            vertical: #"{"frame": "appContent", "rule": {"kind": "centered", "height": 100}}"#,
            expected: CGRect(x: 95, y: 379, width: 200, height: 100)),
        // Fails if: anchorless_geometry.swift `fromWire` `("proportional", .vertical)` reads
        // `pair(wire.startFraction, wire.endFraction)`.
        RuleCase(
            name: "proportional takes its share of each axis",
            horizontal: #"{"frame": "appContent", "rule": {"kind": "proportional", "startFraction": 0.25, "endFraction": 0.75}}"#,
            vertical: #"{"frame": "appContent", "rule": {"kind": "proportional", "topFraction": 0.1, "bottomFraction": 0.2}}"#,
            expected: CGRect(x: 98, y: 123, width: 195, height: 77)),
        // Fails if: anchorless_geometry.swift `.widthScaled` `let top = topRatio * crossExtent` ->
        // `let top = topRatio * extent`.
        RuleCase(
            name: "widthScaled puts the top at a ratio of the frame's width",
            horizontal: #"{"frame": "appContent", "rule": {"kind": "stretch", "startInset": 0, "endInset": 0}}"#,
            vertical: #"{"frame": "appContent", "rule": {"kind": "widthScaled", "topRatio": 0.5, "height": 40}}"#,
            expected: CGRect(x: 0, y: 242, width: 390, height: 40)),
    ]

    @Test("each placement rule lands where it says", arguments: rules)
    func ruleLandsWhereItSays(_ rule: RuleCase) throws {
        func json(_ text: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let result = try resolve(target(horizontal: try json(rule.horizontal), vertical: try json(rule.vertical)))
        #expect(result == .success(rule.expected))
    }

    // Fails if: anchorless_geometry.swift `fromWire` `case ("widthScaled", .vertical):` ->
    // `case ("widthScaled", _):`.
    @Test("a rule authored for the other axis, or a proportional span that runs backwards, makes the target unreadable")
    func malformedRulesDoNotDecode() {
        let full = axis("appContent", ["kind": "stretch", "startInset": 0, "endInset": 0])
        let fullV = axis("appContent", ["kind": "stretch", "topInset": 0, "bottomInset": 0])
        #expect(target(horizontal: axis("appContent", ["kind": "widthScaled", "topRatio": 0.1, "height": 40]),
                       vertical: fullV) == nil)
        #expect(target(horizontal: full,
                       vertical: axis("appContent", ["kind": "endFixed", "endOffset": 0, "width": 40])) == nil)
        #expect(target(horizontal: axis("appContent", ["kind": "proportional", "startFraction": 0.6, "endFraction": 0.4]),
                       vertical: fullV) == nil)
        #expect(target(horizontal: axis("appContent", ["kind": "proportional", "startFraction": 0.2, "endFraction": 1.2]),
                       vertical: fullV) == nil)
    }

    // MARK: - Reference container

    private var container: [String: Any] {
        [
            "horizontal": axis("window", ["kind": "stretch", "startInset": 0, "endInset": 0]),
            "vertical": axis("appContent", ["kind": "topFixed", "topOffset": 100, "height": 300]),
        ]
    }

    // Fails if: anchorless_geometry.swift `resolve` `referenceContainer: referenceRect` ->
    // `referenceContainer: frames.appContent`.
    @Test("a target placed in its reference container is measured from the container")
    func placedInReferenceContainer() throws {
        let result = try resolve(target(
            horizontal: axis("referenceContainer", ["kind": "proportional", "startFraction": 0, "endFraction": 0.5]),
            vertical: axis("referenceContainer", ["kind": "topFixed", "topOffset": 10, "height": 20]),
            referenceContainer: container))
        #expect(result == .success(CGRect(x: 0, y: 157, width: 195, height: 20)))
    }

    // Fails if: anchorless_geometry.swift `decode` `guard usesReference == (referenceContainer != nil)`
    // is deleted.
    @Test("a reference container must be used, must not refer to itself, and must be present when used")
    func referenceContainerContract() {
        let inContainer = axis("referenceContainer", ["kind": "topFixed", "topOffset": 10, "height": 20])
        let full = axis("appContent", ["kind": "stretch", "startInset": 0, "endInset": 0])
        let top = axis("appContent", ["kind": "topFixed", "topOffset": 10, "height": 20])
        #expect(target(horizontal: full, vertical: inContainer) == nil, "used but missing")
        #expect(target(horizontal: full, vertical: top, referenceContainer: container) == nil, "present but unused")
        var nested = container
        nested["vertical"] = axis("referenceContainer", ["kind": "topFixed", "topOffset": 0, "height": 10])
        #expect(target(horizontal: full, vertical: inContainer, referenceContainer: nested) == nil,
                "a container placed in a container")
    }

    // Fails if: anchorless_geometry.swift `resolve` `if referenceContainer != nil, referenceRect == nil {
    // return .failure(.invalidGeometry) }` is deleted (the target is then placed against a container
    // that does not fit, and falls back to nothing sensible).
    @Test("a reference container that does not fit on this screen fails the target as invalid geometry")
    func containerOffScreenIsInvalid() throws {
        var offScreen = container
        offScreen["vertical"] = axis("appContent", ["kind": "topFixed", "topOffset": 700, "height": 300])
        let result = try resolve(target(
            horizontal: axis("appContent", ["kind": "stretch", "startInset": 0, "endInset": 0]),
            vertical: axis("referenceContainer", ["kind": "topFixed", "topOffset": 0, "height": 20]),
            referenceContainer: offScreen))
        #expect(result == .failure(.invalidGeometry))
    }

    // Fails if: anchorless_geometry.swift `resolve` `safeInsets.top >= 0,` is deleted.
    @Test("a window reporting a negative safe-area inset is refused rather than measured")
    func negativeInsetIsInvalid() throws {
        let topFixed = target(
            horizontal: axis("appContent", ["kind": "startFixed", "startOffset": 0, "width": 100]),
            vertical: axis("appContent", ["kind": "topFixed", "topOffset": 100, "height": 50]))
        let result = try resolve(topFixed, in: window(insets: UIEdgeInsets(top: -20, left: 0, bottom: 34, right: 0)))
        #expect(result == .failure(.invalidGeometry))
    }
}
