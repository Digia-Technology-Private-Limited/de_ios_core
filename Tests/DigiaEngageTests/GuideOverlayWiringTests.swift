import Foundation
import XCTest
@testable import DigiaEngage

final class GuideOverlayWiringTests: XCTestCase {
    func testHostConsumesOnlyTheThreeTargetOutcomes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DigiaEngage/api/widgets/guide_overlay_view.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "resolveTarget(").count - 1, 1)
        XCTAssertFalse(source.contains("getRect(for:"))
        XCTAssertFalse(source.contains("getCornerRadius(for:"))
        XCTAssertFalse(source.contains("AnchorlessRuntime"))
        XCTAssertFalse(source.contains("Capture"))
        XCTAssertTrue(source.contains("case let .ready"))
        XCTAssertTrue(source.contains("case .notReady"))
        XCTAssertTrue(source.contains("case let .failed"))
        XCTAssertTrue(source.contains("calloutGap"))
        XCTAssertTrue(source.contains("cornerRadius: cornerRadius"))
    }

    func testOutcomeConsumerIsModeBlindAndFailedIsEmpty() {
        XCTAssertEqual(GuideOverlayTargetConsumer.renderState(.ready(
            rect: .zero, cornerRadius: 12
        )), .ready)
        XCTAssertEqual(GuideOverlayTargetConsumer.renderState(.notReady), .waiting)
        XCTAssertEqual(GuideOverlayTargetConsumer.renderState(.failed(.rectOutsideFrame)), .hidden)
        XCTAssertEqual(GuideOverlayTargetConsumer.renderState(.failed(nil)), .hidden)
    }
}
