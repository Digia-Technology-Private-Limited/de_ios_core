import Foundation
import Testing

@testable import DigiaEngage

private final class HostSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []
    var records: [TimelineRecord] { lock.withLock { stored } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
}

@MainActor
private func readySDK(campaigns: [[String: Any]]) async throws -> SDKInstance {
    let network = HeldBundleNetworkClient()
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

/// Flutter: `test/host_trigger_test.dart` — the host driver's delivery path.
@MainActor
@Suite("DMC host trigger", .serialized)
struct DMCHostTriggerTests {
    private func nudge(_ key: String, extra: [String: Any] = [:]) -> [String: Any] {
        var json: [String: Any] = [
            "id": "id-\(key)",
            "campaignKey": key,
            "campaignType": "nudge",
            "status": "active",
            "rule": [
                "priority": 600,
                "trigger": ["any": [["type": "event", "name": "never_fired"]]],
                "conditions": ["all": [Any]()],
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

    @Test("triggerCampaign routes a stored campaign and respects the cap")
    func routesAndRespectsCap() async throws {
        let sdk = try await readySDK(campaigns: [
            nudge("host_nudge"), nudge("capped", extra: ["frequency": ["maxTotal": 1]]),
        ])

        _ = sdk.triggerCampaign("host_nudge", variables: nil)

        #expect(sdk.controller.activeNudge?.payload.campaignKey == "host_nudge")
        // No CEP holds a slot, so the host's own id is minted, not a plugin's.
        #expect(sdk.controller.activeNudge?.payload.cepCampaignId.hasPrefix("host:") == true)
        sdk.controller.dismissNudge()

        let services = try #require(sdk.services)
        let capped = try #require(sdk.campaignStore.find("capped"))
        services.frequencyManager.recordShow("capped", capped.frequency)
        let recorder = PresentationRecorder(sdk.triggerCampaign("capped", variables: nil))

        #expect(recorder.dropReason == .frequencyCapped)
        #expect(sdk.controller.activeNudge == nil)
    }

    @Test("a host trigger before initialize drops at once, not silently")
    func dropsBeforeInitialize() {
        let sdk = SDKInstance(
            defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { _ in HeldBundleNetworkClient() })
        #expect(sdk.sdkState == .notInitialized)

        let presentation = sdk.triggerCampaign("home_banner", variables: nil)
        let recorder = PresentationRecorder(presentation)

        guard case .dropped(let reason, let detail) = recorder.outcome else {
            Issue.record("expected a drop, got \(String(describing: recorder.outcome))")
            return
        }
        #expect(reason == .notInitialized)
        #expect(detail == "Digia.initialize() has not been called")
    }
}

/// Flutter: `test/sdk_instance_track_event_test.dart` — `trackEvent`'s two
/// ingestion rules, and the warning each leaves behind.
@MainActor
@Suite("DMC trackEvent ingestion", .serialized)
struct DMCTrackEventTests {
    private func warnings(_ sink: HostSink) -> [TimelineRecord] {
        sink.records.filter { $0.reason?.wire == TimelineReason.appEventInvalid.wire }
    }

    @Test("a name that cannot be stored warns with a bounded sample")
    func unstorableNameWarns() async throws {
        let sink = HostSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        let sdk = try await readySDK(campaigns: [])

        sdk.trackEvent(String(repeating: "x", count: appEventNameMaxLength + 10))
        sdk.trackEvent("")

        // The sample is cut to the limit the backend stores, so an offending
        // name cannot grow the ring buffer.
        #expect(warnings(sink).map { $0.extras["event_name"] } == [
            String(repeating: "x", count: appEventNameMaxLength), "",
        ])
        #expect(warnings(sink).allSatisfy { $0.stage == .session })
    }

    @Test("a value that cannot be stored is dropped, and the warning names the event")
    func unstorableValueWarns() async throws {
        let sink = HostSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        let sdk = try await readySDK(campaigns: [])

        sdk.trackEvent("add_to_cart", properties: ["sku": "PCM-500", "cart": ["items": 2]])
        // A call whose values are all storable says nothing: the warning is
        // about the call's values, not about trackEvent having been used.
        sdk.trackEvent("add_to_cart", properties: ["sku": "PCM-500"])

        let found = warnings(sink)
        #expect(found.count == 1)
        #expect(found.first?.stage == .session)
        #expect(found.first?.extras["event_name"] == "add_to_cart")
    }

    @Test("trackEvent and setUserAttributes before initialize are ignored, not held for later")
    func beforeInitializeIsIgnored() async throws {
        // initialize() marks the process-wide endpoints as initialized.
        defer { DigiaEndpoints.resetForTest() }
        let campaign: [String: Any] = [
            "id": "id-ev", "campaignKey": "ev", "campaignType": "nudge", "status": "active",
            "rule": [
                "priority": 600,
                "trigger": ["any": [["type": "event", "name": "cart_landed"]]],
                "conditions": ["all": [Any]()],
            ] as [String: Any],
            "templateConfig": [
                "templateType": "nudge", "layoutMode": "canvas",
                "container": ["displayType": "dialog"],
                "canvas": ["version": 2, "canvasWidth": 320, "canvasHeight": 200, "children": [Any]()],
                "variables": [Any](),
            ] as [String: Any],
        ]
        let network = HeldBundleNetworkClient()
        network.release(.success(NetworkResponse(
            statusCode: 200, headers: [:],
            body: try JSONSerialization.data(withJSONObject: ["campaigns": [campaign]]),
            isSuccessful: true)))
        let sdk = SDKInstance(
            defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { _ in network })

        sdk.trackEvent("cart_landed")
        await sdk.setUserAttributes(["plan": "pro"])
        try await sdk.initialize(DigiaConfig(apiKey: "test-api-key"))
        for _ in 0..<300 where sdk.sdkState != .ready { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(sdk.sdkState == .ready)

        // Neither the early event nor the early attributes survived to be applied.
        #expect(sdk.selfTriggerCount == 0)
        #expect(sdk.services?.userContextManager.attributes.isEmpty == true)

        // The same event once ready does fire the campaign, so the zero above is meaningful.
        sdk.trackEvent("cart_landed")
        #expect(sdk.selfTriggerCount == 1)
    }
}
