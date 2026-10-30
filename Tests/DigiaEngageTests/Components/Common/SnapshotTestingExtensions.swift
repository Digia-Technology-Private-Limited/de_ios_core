import Foundation
import SnapshotTesting
import Testing
import UIKit
@testable import DigiaEngage

extension ViewImageConfig {
    /// The visual-golden viewport: the screen of the Flutter and Android goldens (`_screen`,
    /// `_safeTop` / `_safeBottom` in `flutter/core/test/support/sdk_harness.dart`, Android's
    /// `w390dp-h844dp`). The pinned simulator (iPhone 17 Pro Max) is a different size, so a golden that
    /// shows SDK code reading `UIScreen.main` or the key window pins them with `GoldenScreen`.
    public static let engageGolden = ViewImageConfig(
        safeArea: UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0),
        size: CGSize(width: 390, height: 844),
        traits: UITraitCollection(userInterfaceIdiom: .phone)
    )
}

/// Helper to check if golden recording is enabled via environment variable
public var isSnapshotRecordingEnabled: Bool {
    ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "true"
        || ProcessInfo.processInfo.environment["TEST_RUNNER_RECORD_SNAPSHOTS"] == "true"
}

/// Where the goldens of the test file at [filePath] live: `de_workspace/goldens/ios/<file>/`, beside
/// the Flutter and Android copies the goldens reviewer reads, not in this repository. The file's
/// name keeps SnapshotTesting's own `__Snapshots__/<file>/` grouping.
public func goldenDirectory(filePath: String) -> String {
    let file = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
    guard let workspace = FixtureLoader.workspaceURL() else {
        preconditionFailure("No de_workspace above \(filePath): the goldens live in its goldens/ios/")
    }
    return workspace.appendingPathComponent("goldens/ios/\(file)", isDirectory: true).path
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
    let cleanTestName = sanitizeSnapshotTestName(rawTestName)
    let recordMode = isSnapshotRecordingEnabled ? SnapshotTestingConfiguration.Record.all : nil

    let imageSnapshotting = Snapshotting<UIView, UIImage>.image(
        precision: precision,
        perceptualPrecision: perceptualPrecision
    )
    var renderedImage: UIImage?
    let capturingSnapshotting = Snapshotting<UIView, UIImage>(
        pathExtension: imageSnapshotting.pathExtension,
        diffing: imageSnapshotting.diffing
    ) { view in
        imageSnapshotting.snapshot(view).map { image in
            renderedImage = image
            return image
        }
    }

    let failure = verifySnapshot(
        of: view,
        as: capturingSnapshotting,
        named: name,
        record: recordMode,
        snapshotDirectory: goldenDirectory(filePath: "\(filePath)"),
        fileID: fileID,
        file: filePath,
        testName: cleanTestName,
        line: line
    )

    if failure == nil, let renderedImage {
        recordGoldenAttachments(
            actual: renderedImage,
            testName: cleanTestName,
            snapshotName: name,
            sourceFilePath: String(describing: filePath)
        )
    }

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
    let cleanTestName = sanitizeSnapshotTestName(rawTestName)
    let recordMode = isSnapshotRecordingEnabled ? SnapshotTestingConfiguration.Record.all : nil

    let failure = verifySnapshot(
        of: image,
        as: .image(precision: precision, perceptualPrecision: perceptualPrecision),
        named: name,
        record: recordMode,
        snapshotDirectory: goldenDirectory(filePath: "\(filePath)"),
        fileID: fileID,
        file: filePath,
        testName: cleanTestName,
        line: line
    )

    if failure == nil {
        recordGoldenAttachments(
            actual: image,
            testName: cleanTestName,
            snapshotName: name,
            sourceFilePath: String(describing: filePath)
        )
    }

    if let failureMessage = failure {
        Issue.record("\(failureMessage)")
    }
}

@MainActor
private func recordGoldenAttachments(
    actual: UIImage,
    testName: String,
    snapshotName: String?,
    sourceFilePath: String
) {
    let identifier = snapshotName.map(sanitizeSnapshotPathComponent)
    let attachmentStem = identifier.map { "\(testName)-\($0)" } ?? testName
    Attachment.record(actual, named: "\(attachmentStem)-actual", as: .png)

    let snapshotDirectory = URL(fileURLWithPath: goldenDirectory(filePath: sourceFilePath), isDirectory: true)

    guard let snapshotURLs = try? FileManager.default.contentsOfDirectory(
        at: snapshotDirectory,
        includingPropertiesForKeys: nil
    ),
        let referenceURL = snapshotURLs.first(where: { url in
            guard url.pathExtension == "png" else { return false }
            if let identifier {
                return url.deletingPathExtension().lastPathComponent == "\(testName).\(identifier)"
            }
            return url.lastPathComponent.hasPrefix("\(testName).")
        }),
        let referenceData = try? Data(contentsOf: referenceURL)
    else {
        return
    }

    let exactImageDiff = Diffing<UIImage>.image
    let reference = exactImageDiff.fromData(referenceData)
    Attachment.record(reference, named: "\(attachmentStem)-reference", as: .png)

    guard let (_, diffAttachments) = exactImageDiff.diffV2(reference, actual) else {
        return
    }
    for diffAttachment in diffAttachments {
        guard case .data(let data, let attachmentName) = diffAttachment,
              attachmentName == "difference.png"
        else {
            continue
        }
        Attachment.record(data, named: "\(attachmentStem)-difference.png")
    }
}

private func sanitizeSnapshotTestName(_ value: String) -> String {
    let strippedFunctionSignature = value.replacingOccurrences(
        of: "\\(.*\\)",
        with: "",
        options: .regularExpression
    )
    return sanitizeSnapshotPathComponent(strippedFunctionSignature)
}

private func sanitizeSnapshotPathComponent(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\W+", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
}

// MARK: - Swift Testing Hierarchy Snapshot Assertions

/// Normalizes a view hierarchy string by purging memory pointer addresses and cleaning up
/// compiler-mangled Swift/SwiftUI internal type names so snapshots are readable and deterministic.
public func purgeHierarchyPointers(_ string: String) -> String {
    var result = string.replacingOccurrences(
        of: ":?\\s*0x[\\da-fA-F]+(\\s*)",
        with: "$1",
        options: .regularExpression
    )

    // Remove volatile compiler-mangled baseClass attributes
    result = result.replacingOccurrences(
        of: "; baseClass = _Tt[^;>]+",
        with: "",
        options: .regularExpression
    )

    // Normalize compiler-mangled Swift type names to clean, stable identifiers
    result = result.replacingOccurrences(
        of: "_TtGC7SwiftUI21UIKitPlatformViewHost[^;>]+CanvasRichText__",
        with: "CanvasRichTextPlatformViewHost",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: "_TtC11DigiaEngage[^;>]+CanvasRichTextContainerView",
        with: "CanvasRichTextContainerView",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: "_TtGC7SwiftUI14_UIHostingView[^;>]+NudgeOverlayView_",
        with: "_UIHostingView<NudgeOverlayView>",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: "_TtGC7SwiftUI14_UIHostingView[^;>]+CampaignCanvasView_",
        with: "_UIHostingView<CampaignCanvasView>",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: "_TtGC7SwiftUI14_UIHostingView[^;>]*DigiaSlot[^;>]*",
        with: "_UIHostingView<DigiaSlot>",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: "_TtCC7SwiftUI17HostingScrollView17PlatformContainer",
        with: "HostingScrollView.PlatformContainer",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: "_TtCC7SwiftUI17HostingScrollView22PlatformGroupContainer",
        with: "HostingScrollView.PlatformGroupContainer",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: "_TtC7SwiftUI[^;>]+ColorShapeLayer",
        with: "ColorShapeLayer",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: "_TtCGC7SwiftUI29PresentationHostingController[^;>]+HostingView",
        with: "PresentationHostingController.HostingView",
        options: .regularExpression
    )

    return result
}

extension Snapshotting where Value == UIView, Format == String {
    /// A snapshot strategy for comparing view hierarchies based on their recursive description
    /// without re-parenting views or corrupting live SwiftUI hosting trees.
    public static var hierarchy: Snapshotting {
        SimplySnapshotting.lines.pullback { view in
            let description = (view.perform(Selector(("recursiveDescription")))?
                .takeUnretainedValue() as? String) ?? ""
            return purgeHierarchyPointers(description)
        }
    }
}

/// Asserts that a UIView matches its view hierarchy snapshot using Swift Testing.
@MainActor
public func assertHierarchy(
    matching view: UIView,
    named name: String? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    let rawTestName = String(describing: function)
    let cleanTestName = sanitizeSnapshotTestName(rawTestName)
    let recordMode = isSnapshotRecordingEnabled ? SnapshotTestingConfiguration.Record.all : nil

    let failure = verifySnapshot(
        of: view,
        as: .hierarchy,
        named: name,
        record: recordMode,
        snapshotDirectory: goldenDirectory(filePath: "\(filePath)"),
        fileID: fileID,
        file: filePath,
        testName: cleanTestName,
        line: line
    )

    if let failureMessage = failure {
        Issue.record("\(failureMessage)")
    }
}

/// Asserts that a UIViewController matches its controller hierarchy snapshot using Swift Testing.
@MainActor
public func assertHierarchy(
    matching viewController: UIViewController,
    named name: String? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    let rawTestName = String(describing: function)
    let cleanTestName = sanitizeSnapshotTestName(rawTestName)
    let recordMode = isSnapshotRecordingEnabled ? SnapshotTestingConfiguration.Record.all : nil

    let failure = verifySnapshot(
        of: viewController,
        as: .hierarchy,
        named: name,
        record: recordMode,
        snapshotDirectory: goldenDirectory(filePath: "\(filePath)"),
        fileID: fileID,
        file: filePath,
        testName: cleanTestName,
        line: line
    )

    if let failureMessage = failure {
        Issue.record("\(failureMessage)")
    }
}
