import XCTest
@testable import DigiaEngage

final class RenderedTargetObservationV1Tests: XCTestCase {
    func testCorrelatesAndSequencesCommonRendererObservations() throws {
        var now: UInt64 = 100
        let store = RenderedTargetObservationStoreV1(capacity: 3) {
            defer { now += 10 }
            return now
        }

        try store.setRunId("run-ios-assisted-001")
        store.record(
            approach: .assisted,
            stepId: "step-1",
            frameLogical: CGRect(x: 12, y: 24, width: 80, height: 32),
            paddingLogical: 6,
            failureCode: nil
        )
        store.record(
            approach: .assisted,
            stepId: "step-1",
            frameLogical: CGRect(x: 14, y: 24, width: 80, height: 32),
            paddingLogical: 6,
            failureCode: nil
        )

        let observations = store.snapshot(runId: "run-ios-assisted-001")
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations[0].sequence, 1)
        XCTAssertEqual(observations[0].monotonicTimeNs, "100")
        XCTAssertEqual(observations[0].outcome, .presented)
        XCTAssertEqual(observations[1].sequence, 2)
        XCTAssertEqual(observations[1].outcome, .updated)
        XCTAssertEqual(observations[1].frameLogical.right, 94)
        XCTAssertEqual(observations[1].paddingLogical, 6)
    }

    func testFailsClosedWithoutMatchingCorrelation() throws {
        let store = RenderedTargetObservationStoreV1(capacity: 3)
        try store.setRunId("run-ios-assisted-001")
        store.record(
            approach: .semantic,
            stepId: "step-1",
            frameLogical: CGRect(x: 1, y: 2, width: 3, height: 4),
            paddingLogical: 0,
            failureCode: nil
        )

        XCTAssertTrue(store.snapshot(runId: "another-run").isEmpty)
        store.clear()
        store.record(
            approach: .semantic,
            stepId: "step-1",
            frameLogical: CGRect(x: 1, y: 2, width: 3, height: 4),
            paddingLogical: 0,
            failureCode: nil
        )
        XCTAssertTrue(store.snapshot(runId: "run-ios-assisted-001").isEmpty)
        XCTAssertThrowsError(try store.setRunId("../unsafe"))
    }

    func testWritesAHashedNativeExportForTheExactRun() throws {
        let store = RenderedTargetObservationStoreV1(capacity: 3, clock: { 123 })
        try store.setRunId("run-ios-export-001")
        store.record(
            approach: .geometry,
            stepId: "step-2",
            frameLogical: CGRect(x: 10, y: 20, width: 30, height: 40),
            paddingLogical: 4,
            failureCode: nil
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let exporter = TestKitNativeEvidenceExporterV1(
            observationStore: store,
            assistedTraces: { [] },
            baseDirectory: directory
        )

        let exportURL = try exporter.export(runId: "run-ios-export-001")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: exportURL)) as? [String: Any]
        )
        XCTAssertEqual(json["runId"] as? String, "run-ios-export-001")
        XCTAssertEqual((json["sha256"] as? String)?.count, 64)
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let observations = try XCTUnwrap(payload["renderedTargetObservations"] as? [[String: Any]])
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0]["approach"] as? String, "geometry")
        XCTAssertThrowsError(try exporter.export(runId: "wrong-run"))
    }
}
