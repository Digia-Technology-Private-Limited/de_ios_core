import Foundation
import Testing

@testable import DigiaEngage

private final class GateSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []
    var records: [TimelineRecord] { lock.withLock { stored } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
}

/// Flutter: `test/dmc_config_gate_test.dart` — a campaign whose own config
/// cannot render is turned away with its reason, before any surface is claimed.
@MainActor
@Suite("DMC config gate", .serialized)
struct DMCConfigGateTests {
    private func ready() async throws -> SDKInstance {
        let network = HeldBundleNetworkClient()
        let campaigns: [[String: Any]] = [
            // A tooltip guide with an empty step list: parses, has nothing to show.
            [
                "id": "id-empty_guide", "campaignKey": "empty_guide", "campaignType": "guide", "status": "active",
                "templateConfig": ["templateType": "tooltip", "steps": [Any](), "variables": [Any]()] as [String: Any],
            ],
            // A campaign type no SDK build recognises: kept in the store for diagnostics.
            [
                "id": "id-hologram_hero", "campaignKey": "hologram_hero", "campaignType": "hologram",
                "status": "active", "templateConfig": [String: Any](),
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: ["campaigns": campaigns])
        network.release(.success(NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true)))
        let sdk = SDKInstance(
            defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { _ in network })
        try await sdk.initialize(DigiaConfig(apiKey: "test-api-key"))
        for _ in 0..<300 where sdk.sdkState != .ready { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(sdk.sdkState == .ready)
        return sdk
    }

    @Test("a guide with no steps is dropped with the cause on its record")
    func emptyGuideDropped() async throws {
        let sink = GateSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        let sdk = try await ready()

        let recorder = PresentationRecorder(sdk.triggerCampaign("empty_guide", variables: nil))

        guard case .dropped(let reason, let detail) = recorder.outcome else {
            Issue.record("expected a drop, got \(String(describing: recorder.outcome))")
            return
        }
        #expect(reason == .invalidConfig)
        #expect(detail == "guide has no steps")
        #expect(sdk.controller.activeNudge == nil)
        // The timeline row is written once the settled outcome is observed.
        try await Task.sleep(nanoseconds: 50_000_000)
        let drops = sink.records.filter { $0.campaignKey == "empty_guide" && $0.stage == .render }
        #expect(drops.count == 1)
        #expect(drops.first?.reason?.wire == DropReason.invalidConfig.wire)
        #expect(drops.first?.extras == ["cause": "empty_content"])
    }

    @Test("a campaign type this SDK cannot render drops as unsupported")
    func unsupportedTypeDropped() async throws {
        let sdk = try await ready()

        let recorder = PresentationRecorder(sdk.triggerCampaign("hologram_hero", variables: nil))

        guard case .dropped(let reason, let detail) = recorder.outcome else {
            Issue.record("expected a drop, got \(String(describing: recorder.outcome))")
            return
        }
        #expect(reason == .invalidConfig)
        #expect(detail?.contains("hologram rendering is not supported") == true)
        #expect(sdk.controller.activeNudge == nil)
    }
}
