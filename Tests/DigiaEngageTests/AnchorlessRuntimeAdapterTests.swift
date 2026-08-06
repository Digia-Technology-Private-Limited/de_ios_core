import CoreGraphics
import XCTest
@testable import DigiaEngage

final class AnchorlessRuntimeAdapterTests: XCTestCase {
    @MainActor
    func testRuntimeGateFailsClosedAndRecordsOneTrace() {
        let diagnostics = AnchorlessDiagnosticsRing()
        let runtime = AnchorlessRuntime(
            snapshotProvider: FakeSnapshotProvider(snapshot: Self.snapshot),
            deviceStateProvider: FakeDeviceStateProvider(state: AnchorlessDeviceState(
                currentPageKey: "other", orientation: .portrait, formFactor: .phone
            )),
            diagnostics: diagnostics
        )
        switch runtime.resolve(target: Self.target) {
        case let .failed(failure): XCTAssertEqual(failure, .pageKeyMismatch)
        default: XCTFail("A page mismatch must fail closed")
        }
        XCTAssertEqual(diagnostics.traces.count, 1)
        XCTAssertEqual(diagnostics.traces[0].failure, .pageKeyMismatch)
    }

    @MainActor
    func testRuntimeReadsOneSnapshotAndResolves() {
        let provider = CountingSnapshotProvider(snapshot: Self.snapshot)
        let runtime = AnchorlessRuntime(
            snapshotProvider: provider,
            deviceStateProvider: FakeDeviceStateProvider(state: AnchorlessDeviceState(
                currentPageKey: "home", orientation: .portrait, formFactor: .phone
            )),
            diagnostics: NoOpDiagnosticsSink()
        )
        guard case let .resolved(rect, _) = runtime.resolve(target: Self.target) else {
            return XCTFail("Expected a resolved target")
        }
        XCTAssertEqual(rect, ResolvedTargetRect(left: 16, top: 64, right: 136, bottom: 112))
        XCTAssertEqual(provider.readCount, 1)
    }

    @MainActor
    func testAdapterHasOneBlindOutcomeForRegisteredAndAnchorlessTargets() {
        let source = FakeRegisteredAnchorSource(measurement: RegisteredAnchorMeasurement(
            rect: CGRect(x: 2, y: 3, width: 10, height: 11), cornerRadius: 4
        ))
        let runtime = AnchorlessRuntime(
            snapshotProvider: FakeSnapshotProvider(snapshot: Self.snapshot),
            deviceStateProvider: FakeDeviceStateProvider(state: AnchorlessDeviceState(
                currentPageKey: "home", orientation: .portrait, formFactor: .phone
            )),
            diagnostics: NoOpDiagnosticsSink()
        )
        let adapter = GuideTargetAdapter(anchorSource: source, anchorlessRuntime: runtime)
        XCTAssertEqual(
            adapter.resolveTarget(GuideTargetStep(spec: .registeredAnchor(anchorKey: "button"), cornerRadius: 0)),
            .ready(rect: CGRect(x: 2, y: 3, width: 10, height: 11), cornerRadius: 4)
        )
        XCTAssertEqual(
            adapter.resolveTarget(GuideTargetStep(spec: .anchorless(target: Self.target), cornerRadius: 9)),
            .ready(rect: CGRect(x: 16, y: 64, width: 120, height: 48), cornerRadius: 9)
        )
    }

    @MainActor
    func testAdapterDoesNotClampOrTurnFailureIntoNotReady() {
        let runtime = AnchorlessRuntime(
            snapshotProvider: FakeSnapshotProvider(snapshot: Self.snapshot),
            deviceStateProvider: FakeDeviceStateProvider(state: AnchorlessDeviceState(
                currentPageKey: "other", orientation: .portrait, formFactor: .phone
            )),
            diagnostics: NoOpDiagnosticsSink()
        )
        let adapter = GuideTargetAdapter(
            anchorSource: FakeRegisteredAnchorSource(measurement: nil),
            anchorlessRuntime: runtime
        )
        XCTAssertEqual(
            adapter.resolveTarget(GuideTargetStep(spec: .registeredAnchor(anchorKey: "missing"), cornerRadius: 0)),
            .notReady
        )
        XCTAssertEqual(
            adapter.resolveTarget(GuideTargetStep(spec: .anchorless(target: Self.target), cornerRadius: 0)),
            .failed(.pageKeyMismatch)
        )
    }

    private static let snapshot = RuntimeGeometrySnapshot(
        window: FrameRect(left: 0, top: 0, right: 411, bottom: 914),
        appContent: FrameRect(left: 0, top: 24, right: 411, bottom: 866),
        layoutDirection: .ltr
    )

    private static let target: AnchorlessJSONValue = .object([
        "type": .string("anchorless"), "version": .number(1), "mode": .string("element"),
        "variants": .object(["ios": .object([
            "variantId": .string("test-ios"), "devicePlatform": .string("ios"),
            "pageKey": .string("home"), "orientation": .string("portrait"), "logicalUnit": .string("pt"),
            "horizontal": .object(["frame": .string("appContent"), "rule": .object([
                "kind": .string("startFixed"), "startOffset": .number(16), "width": .number(120)
            ])]),
            "vertical": .object(["frame": .string("appContent"), "rule": .object([
                "kind": .string("topFixed"), "topOffset": .number(40), "height": .number(48)
            ])])
        ])])
    ])
}

@MainActor
private struct FakeSnapshotProvider: SnapshotProvider {
    let snapshot: RuntimeGeometrySnapshot?
    func currentSnapshot() -> RuntimeGeometrySnapshot? { snapshot }
}

@MainActor
private final class CountingSnapshotProvider: SnapshotProvider {
    let snapshot: RuntimeGeometrySnapshot?
    private(set) var readCount = 0
    init(snapshot: RuntimeGeometrySnapshot?) { self.snapshot = snapshot }
    func currentSnapshot() -> RuntimeGeometrySnapshot? { readCount += 1; return snapshot }
}

@MainActor
private struct FakeDeviceStateProvider: AnchorlessDeviceStateProvider {
    let state: AnchorlessDeviceState
    func currentDeviceState() -> AnchorlessDeviceState { state }
}

@MainActor
private struct FakeRegisteredAnchorSource: RegisteredAnchorSource {
    let measurement: RegisteredAnchorMeasurement?
    func target(forAnchorKey anchorKey: String) -> RegisteredAnchorMeasurement? { measurement }
}
