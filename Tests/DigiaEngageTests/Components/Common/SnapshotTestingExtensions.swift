import Foundation
import SnapshotTesting
import Testing
import UIKit
@testable import DigiaEngage

extension ViewImageConfig {
    /// Pinned visual-golden viewport used by `run-tests.sh`.
    public static let iPhone17ProMax = ViewImageConfig(
        safeArea: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
        size: CGSize(width: 440, height: 956),
        traits: UITraitCollection(userInterfaceIdiom: .phone)
    )
}

// MARK: - Snapshotting Extensions

extension Snapshotting where Value == UIView, Format == String {
    /// Textual view hierarchy snapshotting that strips runtime memory pointers (e.g. `: 0x600001730140`)
    /// and compiler-generated private symbol hashes (e.g. `P10$10ea6f94014CanvasRichText`) to guarantee
    /// deterministic cross-run and cross-build diffs.
    public static var sanitizedHierarchy: Snapshotting {
        Snapshotting<String, String>.lines.pullback { view in
            let raw = (view.perform(Selector(("recursiveDescription")))?
                .takeUnretainedValue() as? String) ?? ""
            return raw
                .replacingOccurrences(of: #": 0x[0-9a-fA-F]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\$[0-9a-fA-F]+"#, with: "$HASH", options: .regularExpression)
        }
    }
}

/// Helper to check if golden recording is enabled via environment variable
public var isSnapshotRecordingEnabled: Bool {
    ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "true"
}

// MARK: - Swift Testing Visual Golden Assertions

/// Asserts that a UIView matches its visual image golden using Swift Testing.
@MainActor
public func assertVisualGolden(
    matching view: UIView,
    precision: Float = 0.99,
    perceptualPrecision: Float = 0.98,
    named name: String? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    let rawTestName = String(describing: function)
    let cleanTestName = rawTestName.replacingOccurrences(of: "()", with: "")
    let recordMode = isSnapshotRecordingEnabled ? SnapshotTestingConfiguration.Record.all : nil

    let failure = verifySnapshot(
        of: view,
        as: .image(precision: precision, perceptualPrecision: perceptualPrecision),
        named: name,
        record: recordMode,
        fileID: fileID,
        file: filePath,
        testName: cleanTestName,
        line: line
    )

    if let failureMessage = failure {
        Issue.record("\(failureMessage)")
    }
}

/// Asserts that a UIImage matches its visual image golden using Swift Testing.
@MainActor
public func assertVisualGolden(
    matching image: UIImage,
    precision: Float = 0.99,
    perceptualPrecision: Float = 0.98,
    named name: String? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    let rawTestName = String(describing: function)
    let cleanTestName = rawTestName.replacingOccurrences(of: "()", with: "")
    let recordMode = isSnapshotRecordingEnabled ? SnapshotTestingConfiguration.Record.all : nil

    let failure = verifySnapshot(
        of: image,
        as: .image(precision: precision, perceptualPrecision: perceptualPrecision),
        named: name,
        record: recordMode,
        fileID: fileID,
        file: filePath,
        testName: cleanTestName,
        line: line
    )

    if let failureMessage = failure {
        Issue.record("\(failureMessage)")
    }
}
