import Foundation
import Testing

@testable import DigiaEngage

private final class VariablesSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []
    var records: [TimelineRecord] { lock.withLock { stored } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
}

private func baseCampaign(contextVariables: Any? = nil) -> [String: Any] {
    var template: [String: Any] = [
        "templateType": "nudge",
        "layoutMode": "canvas",
        "container": ["displayType": "dialog"],
        "canvas": ["version": 2, "canvasWidth": 320, "canvasHeight": 200, "children": [Any]()],
        "variables": [Any](),
    ]
    if let contextVariables { template["contextVariables"] = contextVariables }
    return [
        "id": "id-1", "campaignKey": "campaign-1", "campaignType": "nudge", "status": "active",
        "templateConfig": template,
    ]
}

private func eventRule(_ name: String, wait: Any? = nil) -> [String: Any] {
    var rule: [String: Any] = [
        "priority": 600,
        "trigger": ["any": [["type": "event", "name": name]]],
        "conditions": ["all": [Any]()],
    ]
    if let wait { rule["wait"] = wait }
    return rule
}

private func nudge(_ key: String, rule: [String: Any], contextVariables: [[String: Any]]) -> [String: Any] {
    var json = baseCampaign(contextVariables: contextVariables)
    json["id"] = "id-\(key)"
    json["campaignKey"] = key
    json["rule"] = rule
    return json
}

/// Flutter: `test/dmc_context_variables_test.dart` — `{{ user.<key> }}` /
/// `{{ event.<key> }}` resolution and trigger-event selection.
@MainActor
@Suite("DMC context variables", .serialized)
struct DMCContextVariablesTests {
    // MARK: campaign parsing

    @Test("tolerates malformed entries and a non-list")
    func toleratesMalformed() throws {
        let campaign = try #require(
            try CampaignModel.fromJson(
                baseCampaign(contextVariables: [
                    "nope",
                    ["namespace": "device", "key": "os"],
                    ["namespace": "user"],
                    ["namespace": "event", "key": "qty", "type": "number"],
                ] as [Any])))

        #expect(campaign.variableSchemas.map(\.name) == ["event.qty"])
        let notAList = try #require(try CampaignModel.fromJson(baseCampaign(contextVariables: "not-a-list")))
        #expect(notAList.variableSchemas.isEmpty)
    }

    @Test("a campaign without contextVariables parses to none")
    func noneDeclared() throws {
        let campaign = try #require(try CampaignModel.fromJson(baseCampaign()))
        #expect(campaign.variableSchemas.isEmpty)
    }

    // MARK: trigger-event selection

    private func boot(_ campaigns: [[String: Any]]) async throws -> SDKInstance {
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

    private func selector(_ sdk: SDKInstance) -> [String: String]? { sdk.controller.activeNudge?.payload.variables }

    private let orEvent = nudge(
        "or_event", rule: eventRule("cart_landed"),
        contextVariables: [
            ["namespace": "user", "key": "firstName", "type": "string"],
            ["namespace": "event", "key": "qty", "type": "number"],
        ])

    @Test("an OR trigger carries the event that fired")
    func orTriggerCarriesEvent() async throws {
        let sdk = try await boot([orEvent])

        sdk.trackEvent("cart_landed", properties: ["qty": 4])

        #expect(selector(sdk)?["event.qty"] == "4")
        // No user attribute set: the string token collapses to its type default.
        #expect(selector(sdk)?["user.firstName"] == "")

        // The render context the nudge actually resolves against sees the token.
        let campaign = try #require(sdk.campaignStore.find("or_event"))
        let context = buildVariableContext(schemas: campaign.variableSchemas, cepVars: selector(sdk))
        #expect(interpolate("Qty: {{ event.qty }}", context: context) == "Qty: 4")
        #expect(interpolate("{{ user.firstName }}", context: context) == "")
    }

    @Test("a user token resolves from the user attributes")
    func userTokenResolves() async throws {
        let sdk = try await boot([orEvent])

        await sdk.setUserAttributes(["firstName": "Priya"])
        sdk.trackEvent("cart_landed", properties: ["qty": 1])

        #expect(selector(sdk)?["user.firstName"] == "Priya")
    }

    @Test("a wait carries the matched event, not the latest")
    func waitCarriesMatchedEvent() async throws {
        let sink = VariablesSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        let awaited = nudge(
            "awaited", rule: eventRule("address_opened", wait: ["type": "delay", "ms": 1000]),
            contextVariables: [["namespace": "event", "key": "qty", "type": "number"]])
        let sdk = try await boot([awaited])

        // Real time: the wait starts a real timer and elapses; a later event
        // must not replace the properties it carried.
        sdk.trackEvent("address_opened", properties: ["qty": 7])
        #expect(
            sink.records.filter {
                $0.campaignKey == "awaited" && $0.reason?.wire == TimelineReason.waitStarted.wire
            }.count == 1)

        sdk.trackEvent("cart_landed", properties: ["qty": 99])
        try await Task.sleep(nanoseconds: 1_300_000_000)

        #expect(sdk.controller.activeNudge?.payload.campaignKey == "awaited")
        #expect(selector(sdk)?["event.qty"] == "7")
    }

    @Test("an app-open trigger leaves the event scope empty")
    func appOpenLeavesEventScopeEmpty() async throws {
        let rule: [String: Any] = [
            "priority": 600,
            "trigger": ["any": [["type": "app_opened"]]],
            "conditions": ["all": [Any]()],
        ]
        let appStart = nudge(
            "app_start", rule: rule,
            contextVariables: [
                ["namespace": "event", "key": "coupon", "type": "string", "fallbackValue": "SAVE10"],
                ["namespace": "event", "key": "qty", "type": "number"],
            ])

        let sdk = try await boot([appStart])

        #expect(sdk.controller.activeNudge?.payload.campaignKey == "app_start")
        #expect(selector(sdk)?["event.coupon"] == "SAVE10")
        #expect(selector(sdk)?["event.qty"] == "0")
    }
}
