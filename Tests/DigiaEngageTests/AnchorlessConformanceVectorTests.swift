import Foundation
import XCTest
@testable import DigiaEngage

final class AnchorlessConformanceVectorTests: XCTestCase {
    func testEverySharedVectorReproducesExactly() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("testkit/contracts/anchorless-solver-vectors.json")
        let data = try Data(contentsOf: fileURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["vectorSchemaVersion"] as? Int, 1)
        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 83)

        for vector in vectors {
            let id = try XCTUnwrap(vector["vectorId"] as? String)
            let target = try XCTUnwrap(AnchorlessPayloadBridge.value(from: vector["target"] as Any))
            let platform = try XCTUnwrap(AnchorlessDevicePlatform(rawValue: vector["devicePlatform"] as! String))

            let prepared: PreparedAnchorlessTarget
            switch AnchorlessSolver.prepare(target: target, platform: platform) {
            case let .prepared(value, _): prepared = value
            case let .rejected(failure, trace):
                let expected = vector["expectedFailure"] as? String
                XCTAssertEqual(failure.rawValue, expected, id)
                XCTAssertEqual(trace.phase, .prepare, id)
                continue
            }

            if let device = vector["device"] as? [String: Any] {
                let state = AnchorlessDeviceState(
                    currentPageKey: device["currentPageKey"] as? String,
                    orientation: AnchorlessOrientation(rawValue: device["orientation"] as! String)!,
                    formFactor: AnchorlessFormFactor(rawValue: device["formFactor"] as! String)!
                )
                let failure = AnchorlessEligibilityGate.evaluate(prepared: prepared, device: state)
                XCTAssertEqual(failure?.rawValue, vector["expectedFailure"] as? String, id)
                continue
            }

            let snapshotObject = try XCTUnwrap(vector["snapshot"] as? [String: Any], id)
            let snapshot = RuntimeGeometrySnapshot(
                window: try frame(snapshotObject["window"]),
                appContent: try frame(snapshotObject["appContent"]),
                layoutDirection: AnchorlessLayoutDirection(
                    rawValue: snapshotObject["layoutDirection"] as! String
                )!
            )
            switch AnchorlessSolver.resolve(prepared: prepared, snapshot: snapshot) {
            case let .resolved(rect, trace):
                let expected = try XCTUnwrap(vector["expectedRect"] as? [String: Any], id)
                XCTAssertEqual(rect, ResolvedTargetRect(
                    left: expected["left"] as! Int,
                    top: expected["top"] as! Int,
                    right: expected["right"] as! Int,
                    bottom: expected["bottom"] as! Int
                ), id)
                XCTAssertNil(vector["expectedFailure"] as? String, id)
                XCTAssertEqual(trace.postRoundingRect, rect, id)
            case let .failed(failure, trace):
                XCTAssertEqual(failure.rawValue, vector["expectedFailure"] as? String, id)
                XCTAssertEqual(trace.phase, .resolve, id)
            }
        }
    }

    func testStepCountIsASeparatePrepareFailure() {
        let result = AnchorlessSolver.prepare(steps: [], platform: .ios)
        XCTAssertEqual(result.failure, .stepCountInvalid)
        XCTAssertEqual(result.trace.phase, .prepare)
    }

    func testNullCropIsStillAForbiddenPresentFieldForElementMode() {
        let target: AnchorlessJSONValue = .object([
            "type": .string("anchorless"), "version": .number(1), "mode": .string("element"),
            "variants": .object(["ios": .object([
                "variantId": .string("v"), "devicePlatform": .string("ios"),
                "pageKey": .string("home"), "orientation": .string("portrait"),
                "logicalUnit": .string("pt"), "crop": .null,
                "horizontal": .object(["frame": .string("window"), "rule": .object([
                    "kind": .string("startFixed"), "startOffset": .number(0), "width": .number(10)
                ])]),
                "vertical": .object(["frame": .string("window"), "rule": .object([
                    "kind": .string("topFixed"), "topOffset": .number(0), "height": .number(10)
                ])])
            ])])
        ])
        XCTAssertEqual(AnchorlessSolver.prepare(target: target, platform: .ios).failure, .invalidModel)
    }

    private func frame(_ object: Any?) throws -> FrameRect {
        let value = try XCTUnwrap(object as? [String: Any])
        return FrameRect(
            left: value["left"] as! Double,
            top: value["top"] as! Double,
            right: value["right"] as! Double,
            bottom: value["bottom"] as! Double
        )
    }
}
