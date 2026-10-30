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

// MARK: - Swift Testing Visual Golden Assertions

/// Asserts that [image] matches `de_workspace/goldens/ios/<surface>/<name>.png`: the layout of the
/// Flutter and Android goldens (`goldens/<platform>/<surface>/<fixture>.png`), so a fixture's three
/// baselines sit side by side under one name. Compared with SnapshotTesting's image diffing.
/// Recording, or a missing baseline, writes the file and fails the test, as SnapshotTesting does.
@MainActor
public func assertSurfaceGolden(
    _ image: UIImage,
    surface: String,
    named name: String,
    precision: Float = 0.99,
    perceptualPrecision: Float = 0.98,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let workspace = FixtureLoader.workspaceURL() else {
        preconditionFailure("No de_workspace found: the goldens live in its goldens/ios/")
    }
    let baseline = workspace.appendingPathComponent("goldens/ios/\(surface)/\(name).png")
    let diffing = Diffing<UIImage>.image(precision: precision, perceptualPrecision: perceptualPrecision)
    Attachment.record(image, named: "\(surface)-\(name)-actual", as: .png)

    guard !isSnapshotRecordingEnabled, let data = try? Data(contentsOf: baseline) else {
        let why = isSnapshotRecordingEnabled ? "Record mode is on." : "No reference was found on disk."
        do {
            try FileManager.default.createDirectory(
                at: baseline.deletingLastPathComponent(), withIntermediateDirectories: true)
            try diffing.toData(image).write(to: baseline)
            Issue.record("\(why) Recorded \(baseline.path); re-run to assert against it.", sourceLocation: sourceLocation)
        } catch {
            Issue.record("Could not record \(baseline.path): \(error)", sourceLocation: sourceLocation)
        }
        return
    }

    let reference = diffing.fromData(data)
    Attachment.record(reference, named: "\(surface)-\(name)-reference", as: .png)
    guard let (message, attachments) = diffing.diffV2(reference, image) else { return }
    for attachment in attachments {
        guard case .data(let difference, let attachmentName) = attachment, attachmentName == "difference.png"
        else { continue }
        Attachment.record(difference, named: "\(surface)-\(name)-difference.png")
    }
    Issue.record("\(surface)/\(name): \(message)", sourceLocation: sourceLocation)
}
