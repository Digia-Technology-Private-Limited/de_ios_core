import Foundation
import XCTest
@testable import DigiaEngage

final class CaptureSessionTests: XCTestCase {
    @MainActor
    func testEachCaptureGateFailsClosedBeforeUploader() async {
        let cases: [(CaptureGateState, CaptureRefusal)] = [
            (CaptureGateState(isDebugBuild: false), .notDebugBuild),
            (CaptureGateState(syncEnabled: false), .syncDisabled),
            (CaptureGateState(captureModeEnabled: false), .captureModeDisabled),
            (CaptureGateState(pairingToken: nil), .pairingMissing),
            (CaptureGateState(pageKey: nil), .pageIdentityMissing),
            (CaptureGateState(connectivityAvailable: false), .offline),
            (CaptureGateState(explicitAction: false), .explicitActionRequired),
        ]
        for (gates, expected) in cases {
            let uploader = RecordingCaptureUploader()
            let session = CaptureSession(gates: gates, uploader: uploader)
            let result = await session.capture(envelope: Self.envelope, png: Data([1, 2, 3]))
            XCTAssertEqual(result, .refused(expected))
            XCTAssertEqual(uploader.calls, 0)
        }
    }

    @MainActor
    func testSuccessfulUploadDoesNotRetainPngAndInFlightIsExclusive() async {
        let uploader = RecordingCaptureUploader(result: .accepted(captureId: "capture-1"))
        let session = CaptureSession(gates: CaptureGateState(), uploader: uploader)
        let result = await session.capture(envelope: Self.envelope, png: Data([9, 8, 7]))
        XCTAssertEqual(result, .uploaded(.accepted(captureId: "capture-1")))
        XCTAssertEqual(uploader.lastPNG, Data([9, 8, 7]))
        XCTAssertFalse(session.isCaptureInFlight)
    }

    @MainActor
    func testDiagnosticsReleaseBindingIsARealNoOpObject() {
        let sink = AnchorlessDiagnostics.makeDefaultSink(isDebugBuild: false)
        XCTAssertTrue(sink is NoOpDiagnosticsSink)
        sink.record(AnchorlessTrace(phase: .resolve, failure: .rectOutsideFrame))
        XCTAssertFalse(sink is AnchorlessDiagnosticsRing)
    }

    private static let envelope = PageCaptureEnvelopeV1(
        pageKey: "home", capturedAt: "2026-08-06T00:00:00.000Z", devicePlatform: .ios,
        binding: .native,
        screenshot: CaptureScreenshotFacts(widthPx: 1, heightPx: 1, byteLength: 3, sha256: String(repeating: "0", count: 64)),
        source: CaptureSourceFrame(
            density: 1, windowBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 1, bottom: 1),
            appContentBoundsPx: CaptureEdgeRect(left: 0, top: 0, right: 1, bottom: 1),
            insetsPx: CaptureInsets(left: 0, top: 0, right: 0, bottom: 0), orientation: .portrait, layoutDirection: .ltr
        ),
        app: CaptureAppFacts(bundleIdentifier: "test", versionName: "1", buildNumber: "1"),
        runtime: CaptureRuntimeFacts(osVersion: "18", locale: "en-IN", fontScale: 1, sdkVersion: "3.9.0", wrapperVersion: nil, formFactor: .phone),
        nodes: [], integrity: CaptureIntegrityFacts(nodeCount: 0, maxDepth: 0, truncated: false, truncationReason: nil)
    )
}

@MainActor
private final class RecordingCaptureUploader: CaptureUploader {
    let result: CaptureUploadResult
    private(set) var calls = 0
    private(set) var lastPNG: Data?
    init(result: CaptureUploadResult = .rejected(.transportFailed)) { self.result = result }
    func upload(envelope: PageCaptureEnvelopeV1, png: Data, pairingToken: String) async -> CaptureUploadResult {
        calls += 1
        lastPNG = png
        return result
    }
}
