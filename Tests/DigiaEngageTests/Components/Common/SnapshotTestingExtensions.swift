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
        fileID: fileID,
        file: filePath,
        testName: cleanTestName,
        line: line
    )

    if failure == nil, let renderedImage {
        recordGoldenAttachments(
            actual: renderedImage,
            testName: cleanTestName,
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

    if failure == nil {
        recordGoldenAttachments(
            actual: image,
            testName: cleanTestName,
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
    sourceFilePath: String
) {
    Attachment.record(actual, named: "\(testName)-actual", as: .png)

    let sourceURL = URL(fileURLWithPath: sourceFilePath)
    let snapshotDirectory = sourceURL
        .deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__", isDirectory: true)
        .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent, isDirectory: true)

    guard let snapshotURLs = try? FileManager.default.contentsOfDirectory(
        at: snapshotDirectory,
        includingPropertiesForKeys: nil
    ),
        let referenceURL = snapshotURLs.first(where: {
            $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix("\(testName).")
        }),
        let referenceData = try? Data(contentsOf: referenceURL)
    else {
        return
    }

    let exactImageDiff = Diffing<UIImage>.image
    let reference = exactImageDiff.fromData(referenceData)
    Attachment.record(reference, named: "\(testName)-reference", as: .png)

    guard let (_, diffAttachments) = exactImageDiff.diffV2(reference, actual) else {
        return
    }
    for diffAttachment in diffAttachments {
        guard case .data(let data, let attachmentName) = diffAttachment,
              attachmentName == "difference.png"
        else {
            continue
        }
        Attachment.record(data, named: "\(testName)-difference.png")
    }
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
    let cleanTestName = rawTestName.replacingOccurrences(of: "()", with: "")
    let recordMode = isSnapshotRecordingEnabled ? SnapshotTestingConfiguration.Record.all : nil

    let failure = verifySnapshot(
        of: view,
        as: .hierarchy,
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
    let cleanTestName = rawTestName.replacingOccurrences(of: "()", with: "")
    let recordMode = isSnapshotRecordingEnabled ? SnapshotTestingConfiguration.Record.all : nil

    let failure = verifySnapshot(
        of: viewController,
        as: .hierarchy,
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

