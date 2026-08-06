// T-1 — Secure-field non-capture. The test this package exists for.
//
// Capture minimization and review gate §9, item **I2**:
//
//     `SemanticViewTree.swift` `ownText` — reads `UITextField.text` and
//     `UITextView.text` with no `isSecureTextEntry` check … a POC path that lifts
//     typed passwords and OTPs into a structured, queryable, project-wide-readable
//     field.
//
// §11 T-1:
//
//     Render a screen with a populated secure text field and a populated ordinary
//     field; assert the serialized capture contains neither string, and that
//     `hasText` is `true` for both.
//
// The second test in this file is the negative control. A test that passes against
// both the POC and the production walker proves nothing, so the same leak scan the
// first test uses is pointed at a POC-shaped node and **must** find the password.
// If the scan is ever weakened, the control fails first and says so.

import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import DigiaEngage

#if canImport(UIKit)
@MainActor
final class CapturePrivacyTests: XCTestCase {

    /// Strings a real user would be horrified to find in a project-wide-readable
    /// record. Distinctive enough that a substring scan cannot miss them.
    private static let typedPassword = "Tr0ub4dor-and-3-hunter2-PASSWORD"
    private static let typedOneTimeCode = "418913-OTP"
    private static let typedOrdinaryString = "Indiranagar, Bengaluru"

    private static let density: CGFloat = 3

    // MARK: - T-1

    func testSecureAndOrdinaryFieldCharactersNeverReachTheSerializedCapture() throws {
        let screen = try Self.makeScreen()

        let envelope = Self.envelope(for: screen)
        let serialized = try XCTUnwrap(CaptureEnvelopeSerializer.jsonBytes(envelope))
        let capture = String(decoding: serialized, as: UTF8.self)

        // 1. Neither string is on the wire, in any field, at any depth.
        for planted in [Self.typedPassword, Self.typedOneTimeCode, Self.typedOrdinaryString] {
            XCTAssertFalse(
                Self.leaks(planted, in: capture),
                "A string typed on screen reached the serialized capture. This is I2."
            )
        }

        // 2. …and the capture is still useful: every populated field says so.
        let populated = envelope.nodes.filter(\.editable)
        XCTAssertEqual(populated.count, 3, "Expected the three entry fields to be walked")
        for node in populated {
            XCTAssertTrue(
                node.hasText,
                "hasText must be true for a populated field — the secure one included"
            )
        }

        // 3. The secure field and the ordinary field are indistinguishable in the
        //    envelope. There is no secure-field branch to forget, because there is
        //    no branch: both took the same path and produced the same shape.
        let secureNode = try XCTUnwrap(populated.first { $0.rootBoundsPx == screen.securePx })
        let ordinaryNode = try XCTUnwrap(populated.first { $0.rootBoundsPx == screen.ordinaryPx })
        XCTAssertEqual(secureNode.hasText, ordinaryNode.hasText)
        XCTAssertEqual(secureNode.editable, ordinaryNode.editable)

        // 4. The envelope carries no prohibited key at all. The allowlist is
        //    enforced by type, so this is a property of the serializer, not a filter.
        let jsonObject = CaptureEnvelopeSerializer.jsonObject(envelope)
        for prohibited in Self.prohibitedKeys {
            XCTAssertFalse(
                Self.containsKey(prohibited, in: jsonObject),
                "Prohibited §3 key '\(prohibited)' is present in the envelope"
            )
        }
    }

    // MARK: - T-1 negative control

    func testNegativeControlPocShapedNodeIsCaughtByTheSameScan() throws {
        // The POC node, reconstructed from I2's description: a structural node with
        // one extra property holding what the user typed. `ownText` is the POC's
        // own field name.
        let pocNode: [String: Any] = [
            "nodeId": "0.2.1",
            "childIndex": 1,
            "ownText": Self.typedPassword,
            "hasText": true,
        ]
        let pocBytes = try JSONSerialization.data(withJSONObject: ["nodes": [pocNode]])
        let pocCapture = String(decoding: pocBytes, as: UTF8.self)

        XCTAssertTrue(
            Self.leaks(Self.typedPassword, in: pocCapture),
            "The leak scan used by T-1 failed to catch a POC-shaped node. "
                + "T-1 is worthless until this passes."
        )
        XCTAssertTrue(Self.containsKey("ownText", in: ["nodes": [pocNode]]))

        // And the production type system cannot express that node at all: there is
        // no initializer parameter, no property, and no serializer key that would
        // accept the string. That is asserted structurally by the fact that this
        // file cannot construct a `CaptureStructuralNode` carrying it — the
        // following is the closest a caller can get, and it is content-free.
        let production = Self.contentFreeNode(hasText: true)
        let productionBytes = try JSONSerialization.data(
            withJSONObject: ["nodes": [Self.serializedNode(production)]]
        )
        XCTAssertFalse(
            Self.leaks(Self.typedPassword, in: String(decoding: productionBytes, as: UTF8.self))
        )
    }

    // MARK: - Leak scan

    /// Substring, case-insensitive, over the whole serialized capture. Deliberately
    /// blunt: any encoding of the string anywhere in the payload is a finding.
    private static func leaks(_ planted: String, in capture: String) -> Bool {
        capture.range(of: planted, options: .caseInsensitive) != nil
    }

    private static func containsKey(_ key: String, in object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            if dictionary[key] != nil { return true }
            return dictionary.values.contains { containsKey(key, in: $0) }
        }
        if let array = object as? [Any] {
            return array.contains { containsKey(key, in: $0) }
        }
        return false
    }

    /// §3, the machine-checkable names.
    private static let prohibitedKeys = [
        "ownText", "descendantText", "contentDescription", "stateDescription",
        "accessibilityValue", "resourceId", "testId", "nativeId",
        "accessibilityIdentifier", "automationId", "className", "typeName",
        "componentName", "sourceFile", "sourceLine", "memoryAddress", "objectId",
        "debugDescription", "reactTag", "extras", "props", "attributes",
        "advertisingId", "deviceName", "manufacturer", "userId", "anonymousId",
        "sessionId", "deviceId",
    ]

    // MARK: - The screen

    struct Screen {
        let window: UIWindow
        let securePx: CaptureEdgeRect
        let ordinaryPx: CaptureEdgeRect
    }

    static func makeScreen() throws -> Screen {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.isHidden = false

        let secure = UITextField(frame: CGRect(x: 16, y: 100, width: 361, height: 44))
        secure.isSecureTextEntry = true
        secure.insertText(typedPassword)

        let oneTimeCode = UITextField(frame: CGRect(x: 16, y: 160, width: 361, height: 44))
        oneTimeCode.isSecureTextEntry = true
        oneTimeCode.insertText(typedOneTimeCode)

        let ordinary = UITextField(frame: CGRect(x: 16, y: 220, width: 361, height: 44))
        ordinary.insertText(typedOrdinaryString)
        ordinary.accessibilityLabel = "Address"

        window.addSubview(secure)
        window.addSubview(oneTimeCode)
        window.addSubview(ordinary)
        window.layoutIfNeeded()

        return Screen(
            window: window,
            securePx: pixels(secure.frame),
            ordinaryPx: pixels(ordinary.frame)
        )
    }

    private static func pixels(_ rect: CGRect) -> CaptureEdgeRect {
        CaptureEdgeRect(
            left: Int((rect.minX * density).rounded()),
            top: Int((rect.minY * density).rounded()),
            right: Int((rect.maxX * density).rounded()),
            bottom: Int((rect.maxY * density).rounded())
        )
    }

    static func envelope(for screen: Screen) -> PageCaptureEnvelopeV1 {
        let bounds = screen.window.bounds
        let windowBoundsPx = CaptureEdgeRect(
            left: 0,
            top: 0,
            right: Int((bounds.width * density).rounded()),
            bottom: Int((bounds.height * density).rounded())
        )
        let walk = CaptureEvidenceWalker.walk(
            root: UIKitCaptureNode(
                view: screen.window,
                rootView: screen.window,
                density: density
            ),
            windowBoundsPx: windowBoundsPx
        )
        return PageCaptureEnvelopeV1(
            pageKey: "t1-secure-field",
            capturedAt: "2026-08-06T00:00:00.000Z",
            devicePlatform: .ios,
            binding: .native,
            screenshot: CaptureScreenshotFacts(
                widthPx: windowBoundsPx.width,
                heightPx: windowBoundsPx.height,
                byteLength: 1,
                sha256: String(repeating: "0", count: 64)
            ),
            source: CaptureSourceFrame(
                density: Double(density),
                windowBoundsPx: windowBoundsPx,
                appContentBoundsPx: windowBoundsPx,
                insetsPx: CaptureInsets(left: 0, top: 0, right: 0, bottom: 0),
                orientation: .portrait,
                layoutDirection: .ltr
            ),
            app: CaptureAppFacts(
                bundleIdentifier: "tech.digia.test",
                versionName: "1.0.0",
                buildNumber: "1"
            ),
            runtime: CaptureRuntimeFacts(
                osVersion: "18.0",
                locale: "en-IN",
                fontScale: 1,
                sdkVersion: "0.0.0-test",
                wrapperVersion: nil,
                formFactor: .phone
            ),
            nodes: walk.nodes,
            integrity: walk.integrity
        )
    }

    static func contentFreeNode(hasText: Bool) -> CaptureStructuralNode {
        CaptureStructuralNode(
            nodeId: "0",
            parentId: nil,
            childIndex: 0,
            paintOrder: 0,
            localBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 10, bottom: 10),
            transformToRoot: .identity,
            rootBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 10, bottom: 10),
            visibleBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 10, bottom: 10),
            clipContainerId: nil,
            clipBoundsPx: nil,
            inheritedShown: true,
            effectiveAlpha: 1,
            visibleFraction: 1,
            visibilityState: .unclipped,
            containerTraits: [],
            scrollAxes: [],
            viewportBoundsPx: nil,
            scrollOffsetPx: nil,
            contentExtentPx: nil,
            scrollParentId: nil,
            virtualized: false,
            role: nil,
            supportedActions: [],
            enabled: true,
            selected: false,
            checked: nil,
            expanded: nil,
            focused: false,
            editable: true,
            hasText: hasText,
            renderedLineCount: hasText ? 1 : 0,
            hasAccessibilityLabel: false,
            valid: true
        )
    }

    static func serializedNode(_ node: CaptureStructuralNode) -> [String: Any] {
        let envelope = PageCaptureEnvelopeV1(
            pageKey: "single-node",
            capturedAt: "2026-08-06T00:00:00.000Z",
            devicePlatform: .ios,
            binding: .native,
            screenshot: CaptureScreenshotFacts(
                widthPx: 1,
                heightPx: 1,
                byteLength: 1,
                sha256: String(repeating: "0", count: 64)
            ),
            source: CaptureSourceFrame(
                density: 3,
                windowBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 10, bottom: 10),
                appContentBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 10, bottom: 10),
                insetsPx: CaptureInsets(left: 0, top: 0, right: 0, bottom: 0),
                orientation: .portrait,
                layoutDirection: .ltr
            ),
            app: CaptureAppFacts(
                bundleIdentifier: "tech.digia.test",
                versionName: "1.0.0",
                buildNumber: "1"
            ),
            runtime: CaptureRuntimeFacts(
                osVersion: "18.0",
                locale: "en-IN",
                fontScale: 1,
                sdkVersion: "0.0.0-test",
                wrapperVersion: nil,
                formFactor: .phone
            ),
            nodes: [node],
            integrity: CaptureIntegrityFacts(
                nodeCount: 1,
                maxDepth: 1,
                truncated: false,
                truncationReason: nil
            )
        )
        let object = CaptureEnvelopeSerializer.jsonObject(envelope)
        return (object["nodes"] as? [[String: Any]])?.first ?? [:]
    }
}
#endif
