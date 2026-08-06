import Foundation
import XCTest
@testable import DigiaEngage

final class AnchorlessArchitectureTests: XCTestCase {
    func testSolverHasNoPlatformImports() throws {
        let files = try sourceFiles(in: "Sources/DigiaEngage/anchorless/solver")
        let source = files.map(readSource).joined(separator: "\n")
        for forbidden in ["import Foundation", "import UIKit", "import CoreGraphics", "import SwiftUI", "import Combine"] {
            XCTAssertFalse(source.contains(forbidden), "ARCH-1: (forbidden)")
        }
        XCTAssertFalse(source.contains("CGRect"), "ARCH-1: UIKit geometry leaked into solver")
        XCTAssertFalse(source.contains("UIWindow"), "ARCH-1: window lookup leaked into solver")
    }

    func testCaptureAndRuntimeTreesDoNotReferenceEachOther() throws {
        let capture = try sourceFiles(in: "Sources/DigiaEngage/capture")
            .map(readSource).joined(separator: "\n")
        let runtime = try sourceFiles(in: "Sources/DigiaEngage/anchorless")
            .map(readSource).joined(separator: "\n")
        XCTAssertFalse(capture.contains("AnchorlessSolver"), "ARCH-2: capture references solver")
        XCTAssertFalse(capture.contains("PreparedAnchorlessTarget"), "ARCH-2: capture references runtime target")
        XCTAssertFalse(runtime.contains("CaptureEnvelope"), "ARCH-2: runtime references capture envelope")
        XCTAssertFalse(runtime.contains("CaptureNode"), "ARCH-2: runtime references capture nodes")
        XCTAssertFalse(runtime.contains("capture/"), "ARCH-2: runtime names capture module")
    }

    func testTreesDoNotImportPresentationHost() throws {
        let files = try (sourceFiles(in: "Sources/DigiaEngage/capture")
            + sourceFiles(in: "Sources/DigiaEngage/anchorless"))
        let source = files.map(readSource).joined(separator: "\n")
        for forbidden in ["GuideOverlayView", "GuideStepOverlay", "GuideSpotlightScrim", "Canvas"] {
            XCTAssertFalse(source.contains(forbidden), "ARCH-3: presentation host leaked into tree")
        }
    }

    private func sourceFiles(in relativePath: String) throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DigiaEngageTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios/core
        let directory = root.appendingPathComponent(relativePath)
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try XCTUnwrap(enumerator?.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        })
    }

    private func readSource(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
