import Foundation
import Testing

@testable import DigiaEngage

private final class RoutingSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []

    var records: [TimelineRecord] { lock.withLock { stored } }

    func accepts(_ record: TimelineRecord) -> Bool { true }

    func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
}

private final class RoutingPlugin: DigiaCEPPlugin {
    let id = "cep"
    func attach(host: DigiaCEPHost) {}
    func detach() {}
}

/// Flutter: `test/dmc_rule_routing_test.dart` — Digia-owned rules routed
/// through `SDKInstance` (dmc-phase1-decisions §4.5).
@MainActor
@Suite("DMC rule routing through SDKInstance", .serialized)
struct DMCRuleRoutingTests {


    /// An SDK that has fetched the bundle below and is ready.
    private static func ready() async throws -> (SDKInstance, RoutingSink) {
        let network = HeldBundleNetworkClient()
        let sdk = SDKInstance(
            defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { _ in network }
        )
        let sink = RoutingSink()
        DigiaLogger.registerSink(sink)
        network.release(.success(bundle))
        try await sdk.initialize(DigiaConfig(apiKey: "test-api-key"))
        for _ in 0..<300 where sdk.sdkState != .ready { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(sdk.sdkState == .ready)
        return (sdk, sink)
    }

    private func active(_ sdk: SDKInstance) -> String? { sdk.controller.activeNudge?.payload.campaignKey }

    private func gating(_ sink: RoutingSink, _ key: String) -> TimelineRecord? {
        let found = sink.records.filter { $0.campaignKey == key && $0.stage == .gating }
        #expect(found.count == 1, "expected one gating record for \(key), got \(found.count)")
        return found.first
    }

    @Test("the highest priority wins and the others are held back")
    func highestPriorityWins() async throws {
        let (sdk, sink) = try await Self.ready()
        defer { DigiaLogger.unregisterSink(sink) }

        sdk.trackEvent("cart_landed")

        #expect(active(sdk) == "high")
        let held = gating(sink, "low")
        #expect(held?.reason?.wire == TimelineReason.lowerPriority.wire)
        #expect(held?.extras == ["verdict": "eligible", "outcome": "held_back", "lost_to": "high"])
    }

    @Test("each ineligible campaign records its reason")
    func ineligibleReasons() async throws {
        let (sdk, sink) = try await Self.ready()
        defer { DigiaLogger.unregisterSink(sink) }
        let services = try #require(sdk.services)
        let capped = try #require(sdk.campaignStore.find("routing_capped"))
        services.frequencyManager.recordShow("routing_capped", capped.frequency)

        sdk.trackEvent("cart_landed")

        #expect(gating(sink, "routing_gated")?.reason?.wire == TimelineReason.notInAudience.wire)
        #expect(gating(sink, "routing_capped")?.reason?.wire == TimelineReason.capped.wire)
        #expect(gating(sink, "vip_only")?.reason?.wire == TimelineReason.conditionFailed.wire)
        #expect(gating(sink, "broken")?.reason?.wire == TimelineReason.malformedRule.wire)
        #expect(gating(sink, "routing_gated")?.extras == ["verdict": "ineligible", "context": "missing"])
        #expect(gating(sink, "vip_only")?.extras == ["verdict": "ineligible", "condition": "attribute.plan"])
        #expect(gating(sink, "broken")?.extras == ["verdict": "ineligible", "exception_class": "parse"])
    }

    @Test("a malformed rule is logged once")
    func malformedLoggedOnce() async throws {
        let (sdk, sink) = try await Self.ready()
        defer { DigiaLogger.unregisterSink(sink) }

        sdk.trackEvent("cart_landed")
        sdk.controller.dismissNudge()
        sdk.trackEvent("cart_landed")

        let reports = sink.records.filter {
            $0.campaignKey == "broken" && $0.reason?.wire == TimelineReason.malformedRule.wire
        }
        #expect(reports.count == 1)
    }

    @Test("a busy surface drops the winner with no fallback")
    func busySurfaceNoFallback() async throws {
        let (sdk, sink) = try await Self.ready()
        defer { DigiaLogger.unregisterSink(sink) }

        sdk.trackEvent("cart_landed")
        let first = sdk.controller.activeNudge

        sdk.trackEvent("cart_landed")

        #expect(sdk.controller.activeNudge == first)
        #expect(sink.records.filter { $0.campaignKey == "rank_two" && $0.stage != .gating }.isEmpty)
    }

    @Test("a screen rule fires with no plugin registered (#163)")
    func screenRuleNoPlugin() async throws {
        let (sdk, sink) = try await Self.ready()
        defer { DigiaLogger.unregisterSink(sink) }

        sdk.setCurrentScreen("Cart")

        #expect(active(sdk) == "on_cart")
    }

    @Test("a property over 512 characters is cut before the rule sees it (D7)")
    func longPropertyCut() async throws {
        let (sdk, sink) = try await Self.ready()
        defer { DigiaLogger.unregisterSink(sink) }

        sdk.trackEvent("note_saved", properties: ["note": String(repeating: "a", count: appEventPropertyStringMaxLength + 88)])

        #expect(active(sdk) == "note_saver")
    }

    @Test("the event name is trimmed before the rule matches it")
    func eventNameTrimmed() async throws {
        let (sdk, sink) = try await Self.ready()
        defer { DigiaLogger.unregisterSink(sink) }

        sdk.trackEvent("  login_submitted  ")

        #expect(active(sdk) == "trimmed_tip")
    }

    @Test("a CEP trigger for a Digia-decided campaign is dropped")
    func cepTriggerDropped() async throws {
        let (sdk, sink) = try await Self.ready()
        defer { DigiaLogger.unregisterSink(sink) }
        sdk.register(RoutingPlugin())

        let recorder = PresentationRecorder(
            sdk.deliver(CEPTriggerPayload(cepCampaignId: "cep-1", campaignKey: "high", cepMetadata: [:]))
        )

        #expect(recorder.dropReason == .digiaManaged)
        #expect(active(sdk) != "high")
    }

    // MARK: fixtures

    private static var bundle: NetworkResponse {
        let campaigns: [[String: Any]] = [
            nudge("low", 400, event("cart_landed")),
            nudge("high", 800, event("cart_landed")),
            nudge("routing_gated", 1, event("cart_landed"), extra: ["audienceGated": true]),
            nudge("routing_capped", 1, event("cart_landed"), extra: ["frequency": ["maxTotal": 1]]),
            nudge(
                "vip_only", 1, event("cart_landed"),
                conditions: ["type": "attribute", "key": "plan", "op": "eq", "value": "vip"]),
            nudge("broken", 1, event("cart_landed"), conditions: "vip"),
            nudge("on_cart", 1, [["type": "screen_viewed", "names": ["Cart"]]]),
            // D7: the rule sees the value the server stores, cut at 512
            // characters, and the trimmed event name.
            nudge("note_saver", 700, [[
                "type": "event", "name": "note_saved",
                "where": [
                    "type": "prop", "key": "note", "op": "eq",
                    "value": String(repeating: "a", count: appEventPropertyStringMaxLength),
                ],
            ]]),
            nudge("trimmed_tip", 750, [["type": "event", "name": "login_submitted"]]),
        ]
        let body = try! JSONSerialization.data(withJSONObject: ["campaigns": campaigns])
        return NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true)
    }

    private static func event(_ name: String) -> [[String: Any]] { [["type": "event", "name": name]] }

    private static func nudge(
        _ key: String, _ priority: Int, _ triggers: [[String: Any]],
        conditions: Any? = nil, extra: [String: Any] = [:]
    ) -> [String: Any] {
        var json: [String: Any] = [
            "id": "id-\(key)",
            "campaignKey": key,
            "campaignType": "nudge",
            "status": "active",
            "rule": [
                "priority": priority,
                "trigger": ["any": triggers],
                "conditions": conditions ?? ["all": [Any]()],
            ] as [String: Any],
            "templateConfig": [
                "templateType": "nudge",
                "layoutMode": "canvas",
                "container": ["displayType": "dialog"],
                "canvas": ["version": 2, "canvasWidth": 320, "canvasHeight": 200, "children": [Any]()],
                "variables": [Any](),
            ] as [String: Any],
        ]
        json.merge(extra) { _, new in new }
        return json
    }
}
