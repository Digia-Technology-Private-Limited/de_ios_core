import Foundation
import Testing

@testable import DigiaEngage

private final class TimerSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []
    var records: [TimelineRecord] { lock.withLock { stored } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
}

/// Flutter: `test/dmc_inline_timer_test.dart` — a stateful inline timer through routing: the time
/// variable decides whether the campaign can render at all, and a renderable one is handed to its
/// slot with its instant pinned.
@MainActor
@Suite("DMC inline timer", .serialized)
struct DMCInlineTimerTests {
    private func timer(_ key: String, slot: String, deadline: [String: Any]) -> [String: Any] {
        [
            "id": "id-\(key)", "campaignKey": key, "campaignType": "inline", "status": "active",
            "templateConfig": [
                "slotKey": slot,
                "variables": [Any](),
                "stateful": [
                    "version": 1,
                    "sources": [["kind": "timer", "mode": "countdown", "deadline": deadline]],
                    "rules": [[
                        "id": "r1",
                        "canvas": ["version": 2, "canvasWidth": 320, "canvasHeight": 80, "children": [Any]()],
                    ]],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private func ready() async throws -> SDKInstance {
        let network = HeldBundleNetworkClient()
        let campaigns = [
            timer("flash_sale_timer", slot: "flash_timer", deadline: ["source": "fixed", "at": "2035-06-01T00:00:00"]),
            timer("vip_timer", slot: "vip_timer", deadline: ["source": "fromVariable", "token": "promo_deadline"]),
        ]
        let body = try JSONSerialization.data(withJSONObject: ["campaigns": campaigns])
        network.release(.success(NetworkResponse(
            statusCode: 200, headers: ["X-Digia-Server-Time-Ms": "1900000000000"], body: body, isSuccessful: true)))
        let sdk = SDKInstance(
            defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { _ in network })
        try await sdk.initialize(DigiaConfig(apiKey: "test-api-key"))
        for _ in 0..<300 where sdk.sdkState != .ready { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(sdk.sdkState == .ready)
        return sdk
    }

    @Test("a timer whose time variable never resolves is dropped before its slot")
    func unresolvedVariableDropped() async throws {
        let sink = TimerSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        let sdk = try await ready()

        let recorder = PresentationRecorder(sdk.triggerCampaign("vip_timer", variables: nil))

        guard case .dropped(let reason, let detail) = recorder.outcome else {
            Issue.record("expected a drop, got \(String(describing: recorder.outcome))")
            return
        }
        #expect(reason == .invalidConfig)
        #expect(detail == "timer time variable could not be resolved")
        #expect(sdk.inlineController.getCampaign("vip_timer") == nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        let drops = sink.records.filter { $0.campaignKey == "vip_timer" && $0.stage == .render }
        #expect(drops.count == 1)
        #expect(drops.first?.extras == ["cause": "timer_precondition"])
    }

    @Test("a renderable timer fills its slot with its deadline pinned")
    func renderableTimerFillsSlot() async throws {
        let sdk = try await ready()

        _ = PresentationRecorder(sdk.triggerCampaign("flash_sale_timer", variables: nil))

        #expect(sdk.inlineController.getCampaign("flash_timer")?.campaignKey == "flash_sale_timer")
        let resolved = sdk.inlineController.getCanvasConfig("flash_timer")?.statefulTimer?.resolve([:])
        #expect(resolved?.deadlineSource == "fixed")
        // 2035-06-01 is far past the pinned 2030 server time.
        #expect((resolved?.remainingSeconds ?? 0) > 0)
    }
}

/// Flutter: `test/inline_timer_variable_test.dart`.
@Suite("DMC inline timer variable")
struct DMCInlineTimerVariableTests {
    private let source = TimerInstantSource.fromVariable("ends_at")
    private let schemas = [
        VariableSchema(name: "ends_at", type: "string", fallbackValue: "2030-01-01T00:00:00Z")
    ]

    private func resolve(_ sent: String) -> Int64? {
        source.resolve(buildVariableContext(schemas: schemas, cepVars: ["ends_at": sent]).values)
    }

    @Test("a timer variable the trigger leaves empty uses its fallback")
    func emptyUsesFallback() {
        #expect(resolve("") == 1_893_456_000_000)
    }

    @Test("a timer variable the trigger sends wins over the fallback")
    func sentValueWins() {
        #expect(resolve("2031-06-01T00:00:00Z") == 1_938_038_400_000)
    }
}
