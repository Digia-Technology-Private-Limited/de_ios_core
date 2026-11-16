import Foundation
import Testing

@testable import DigiaEngage

private final class WaitSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []
    var records: [TimelineRecord] { lock.withLock { stored } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
}

private final class WaitPlugin: DigiaCEPPlugin {
    let id = "cep"
    var hostReady = false
    var host: DigiaCEPHost?
    func attach(host: DigiaCEPHost) { self.host = host }
    func detach() {}
    func onHostReady() { hostReady = true }
}

/// The campaign bundle answers at once; each `/userContext` request waits
/// until the test answers it.
private final class ContextNetworkClient: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private let bundle: NetworkResponse
    private var waiters: [CheckedContinuation<NetworkResponse, Error>] = []

    init(bundle: NetworkResponse) { self.bundle = bundle }

    var requestCount: Int { lock.withLock { waiters.count } }

    func release(_ index: Int, campaigns: [String]) {
        let body = try! JSONSerialization.data(withJSONObject: [
            "campaigns": campaigns, "attributes": [String: Any](), "expiresInSeconds": 900,
        ] as [String: Any])
        let waiter = lock.withLock { waiters[index] }
        waiter.resume(returning: NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true))
    }

    func fail(_ index: Int) {
        let waiter = lock.withLock { waiters[index] }
        waiter.resume(throwing: URLError(.timedOut))
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        let path = request.url.absoluteString
        if path.hasSuffix("/getCampaignBundle") { return bundle }
        guard path.hasSuffix("/userContext") else {
            return NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8), isSuccessful: true)
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
    }

    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        MockNetworkClient().openSseStream(request: request, handler: handler)
    }
}

/// R58 / de_workspace#192: the SDK is ready without `/userContext`, and only a
/// campaign gated on the audience waits for it. The test controls when the
/// context answers. Flutter: `test/dmc_context_wait_test.dart`.
@MainActor
@Suite("DMC context wait", .serialized)
struct DMCContextWaitTests {

    private struct World {
        let sdk: SDKInstance
        let network: ContextNetworkClient
        let sink: WaitSink
        let plugin: WaitPlugin
    }

    /// Initializes over `campaigns`. `user` is restored from storage, so the
    /// launch asks for the context, which stays held until the test answers.
    private static func launch(_ campaigns: [[String: Any]], user: String? = "A") async throws -> World {
        let body = try! JSONSerialization.data(withJSONObject: ["campaigns": campaigns])
        let network = ContextNetworkClient(
            bundle: NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true))
        let defaults = UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
        if let user { defaults.set(user, forKey: "identity.user_id") }
        let sdk = SDKInstance(
            defaults: defaults,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { _ in network }
        )
        let sink = WaitSink()
        DigiaLogger.registerSink(sink)
        let plugin = WaitPlugin()
        sdk.register(plugin)
        Task { @MainActor in try? await sdk.initialize(DigiaConfig(apiKey: "test-api-key")) }
        try await until { sdk.sdkState == .ready }
        if user != nil { try await until { network.requestCount > 0 } }
        return World(sdk: sdk, network: network, sink: sink, plugin: plugin)
    }

    private static func until(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<300 where !done() { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(done(), "timed out waiting")
    }

    private static func settle() async throws { try await Task.sleep(nanoseconds: 150_000_000) }

    private func shown(_ sdk: SDKInstance) -> String? { sdk.controller.activeNudge?.payload.campaignKey }

    private func logged(_ world: World, _ key: String, _ reason: TimelineReason) -> Bool {
        world.sink.records.contains { $0.campaignKey == key && $0.reason?.wire == reason.wire }
    }

    // dmc-case: dmc.context.cep_not_blocked
    @Test("1. a CEP in-app is not blocked: ready, host told, shown")
    func cepNotBlocked() async throws {
        let world = try await Self.launch([Self.nudge("cep", 100, nil)])
        defer { DigiaLogger.unregisterSink(world.sink) }

        #expect(world.network.requestCount == 1, "/userContext is held")
        #expect(world.plugin.hostReady)
        let recorder = PresentationRecorder(
            world.sdk.deliver(CEPTriggerPayload(cepCampaignId: "cep-1", campaignKey: "cep", cepMetadata: [:])))
        #expect(recorder.dropReason != .notReady)
        #expect(shown(world.sdk) == "cep")
    }

    // dmc-case: dmc.context.ungated_shows_during_wait
    @Test("2. an ungated campaign shows while /userContext is held")
    func ungatedShowsDuringWait() async throws {
        let world = try await Self.launch([Self.nudge("ungated", 100, Self.appOpened)])
        defer { DigiaLogger.unregisterSink(world.sink) }

        try await Self.until { shown(world.sdk) == "ungated" }
    }

    // dmc-case: dmc.context.gated_waits_then_shows
    @Test("3. a gated campaign waits for the context, then shows once")
    func gatedWaitsThenShows() async throws {
        let world = try await Self.launch([Self.nudge("gated", 100, Self.appOpened, gated: true)])
        defer { DigiaLogger.unregisterSink(world.sink) }
        try await Self.settle()
        #expect(shown(world.sdk) == nil)

        world.network.release(0, campaigns: ["gated"])
        try await Self.until { shown(world.sdk) == "gated" }
        world.sdk.controller.dismissNudge()
        try await Self.settle()
        #expect(shown(world.sdk) == nil, "the held trigger replays once")
    }

    // dmc-case: dmc.context.gated_not_in_audience
    @Test("4. a user outside the audience sees nothing and no counter moves")
    func notInAudience() async throws {
        let world = try await Self.launch([
            Self.nudge("gated", 100, Self.appOpened, gated: true, extra: ["frequency": ["maxTotal": 1]])
        ])
        defer { DigiaLogger.unregisterSink(world.sink) }

        world.network.release(0, campaigns: [])
        try await Self.until { logged(world, "gated", TimelineReason.notInAudience) }

        #expect(shown(world.sdk) == nil)
        let campaign = try #require(world.sdk.campaignStore.find("gated"))
        #expect(world.sdk.services?.frequencyManager.blockReason(campaignKey: "gated", policy: campaign.frequency) == nil)
    }

    // dmc-case: dmc.context.refresh_fails
    @Test("5. a failed refresh replays gated triggers against no context")
    func refreshFails() async throws {
        let world = try await Self.launch([
            Self.nudge("ungated", 100, Self.appOpened),
            Self.nudge("gated", 900, Self.appOpened, gated: true),
        ])
        defer { DigiaLogger.unregisterSink(world.sink) }
        try await Self.until { shown(world.sdk) == "ungated" }

        world.network.fail(0)
        try await Self.until { logged(world, "gated", TimelineReason.notInAudience) }

        #expect(shown(world.sdk) == "ungated")
        #expect(world.sdk.sdkState == .ready)
    }

    // dmc-case: dmc.context.reset_during_wait
    @Test("6. a reset during the wait replays nothing and spares the new one")
    func resetDuringWait() async throws {
        let campaigns = [
            Self.nudge("gated", 100, Self.event("go"), gated: true),
            Self.nudge("ungated", 100, Self.event("go_now")),
        ]
        let old = try await Self.launch(campaigns)
        defer { DigiaLogger.unregisterSink(old.sink) }
        old.sdk.trackEvent("go")

        old.sdk.resetForTesting()
        let fresh = try await Self.launch(campaigns, user: nil)
        defer { DigiaLogger.unregisterSink(fresh.sink) }
        old.network.release(0, campaigns: ["gated"])
        try await Self.settle()
        #expect(shown(old.sdk) == nil)
        #expect(shown(fresh.sdk) == nil)

        fresh.sdk.trackEvent("go_now")
        #expect(shown(fresh.sdk) == "ungated", "the new instance is not held")
    }

    // dmc-case: dmc.context.login_opens_new_wait
    @Test("7. a login opens a new wait; the old user's answer does not end it")
    func loginOpensNewWait() async throws {
        let world = try await Self.launch([Self.nudge("gated", 100, Self.event("login_success"), gated: true)])
        defer { DigiaLogger.unregisterSink(world.sink) }

        world.sdk.setUserId("B")
        try await Self.until { world.network.requestCount == 2 }
        world.sdk.trackEvent("login_success")
        #expect(shown(world.sdk) == nil)

        world.network.release(0, campaigns: ["gated"])
        try await Self.settle()
        #expect(shown(world.sdk) == nil, "A's answer is not B's")

        world.network.release(1, campaigns: ["gated"])
        try await Self.until { shown(world.sdk) == "gated" }
    }

    @Test("11. a trigger sent in the same tick as setUserId is held")
    func sameTickLoginIsHeld() async throws {
        let world = try await Self.launch([Self.nudge("gated", 100, Self.event("login_success"), gated: true)])
        defer { DigiaLogger.unregisterSink(world.sink) }
        world.network.release(0, campaigns: [])
        try await Self.settle()

        world.sdk.setUserId("B")
        world.sdk.trackEvent("login_success")
        #expect(!logged(world, "gated", .notInAudience))
        #expect(shown(world.sdk) == nil)

        try await Self.until { world.network.requestCount == 2 }
        world.network.release(1, campaigns: ["gated"])
        try await Self.until { shown(world.sdk) == "gated" }
    }

    // dmc-case: dmc.context.first_ready_wins
    @Test("8. first ready wins: the ungated campaign takes the slot")
    func firstReadyWins() async throws {
        let world = try await Self.launch([
            Self.nudge("ungated", 100, Self.appOpened),
            Self.nudge("gated", 900, Self.appOpened, gated: true),
        ])
        defer { DigiaLogger.unregisterSink(world.sink) }
        try await Self.until { shown(world.sdk) == "ungated" }

        world.network.release(0, campaigns: ["gated"])
        try await Self.until {
            world.sink.records.contains { $0.campaignKey == "gated" && $0.message.contains("surface_busy") }
        }
        #expect(shown(world.sdk) == "ungated")
    }

    // dmc-case: dmc.context.gated_inline_fills
    @Test("9. a gated inline slot is empty during the wait, then fills")
    func gatedInlineFills() async throws {
        let world = try await Self.launch([Self.inline("hero", "home", gated: true)])
        defer { DigiaLogger.unregisterSink(world.sink) }

        world.sdk.slotExposed("home")
        #expect(world.sdk.inlineController.getCampaign("home") == nil)

        world.network.release(0, campaigns: ["hero"])
        try await Self.until { world.sdk.inlineController.getCampaign("home") != nil }
        #expect(world.sdk.inlineController.getCampaign("home")?.campaignKey == "hero")
    }

    // dmc-case: dmc.context.no_refresh_no_wait
    @Test("10. with no refresh in flight nothing waits")
    func noRefreshNoWait() async throws {
        let world = try await Self.launch([Self.nudge("gated", 100, Self.event("go"), gated: true)], user: nil)
        defer { DigiaLogger.unregisterSink(world.sink) }
        #expect(world.network.requestCount == 0)

        world.sdk.trackEvent("go")

        #expect(logged(world, "gated", TimelineReason.notInAudience), "decided at once, not held")
    }

    // MARK: fixtures

    private static let appOpened: [[String: Any]] = [["type": "app_opened"]]

    private static func event(_ name: String) -> [[String: Any]] { [["type": "event", "name": name]] }

    private static func nudge(
        _ key: String, _ priority: Int, _ triggers: [[String: Any]]?,
        gated: Bool = false, extra: [String: Any] = [:]
    ) -> [String: Any] {
        var json: [String: Any] = [
            "id": "id-\(key)",
            "campaignKey": key,
            "campaignType": "nudge",
            "status": "active",
            "audienceGated": gated,
            "templateConfig": [
                "templateType": "nudge",
                "layoutMode": "canvas",
                "container": ["displayType": "dialog"],
                "canvas": ["version": 2, "canvasWidth": 320, "canvasHeight": 200, "children": [Any]()],
                "variables": [Any](),
            ] as [String: Any],
        ]
        if let triggers {
            json["rule"] = [
                "priority": priority,
                "trigger": ["any": triggers],
                "conditions": ["all": [Any]()],
            ] as [String: Any]
        }
        for (name, value) in extra { json[name] = value }
        return json
    }

    private static func inline(_ key: String, _ slot: String, gated: Bool) -> [String: Any] {
        [
            "id": "id-\(key)",
            "campaignKey": key,
            "campaignType": "inline",
            "status": "active",
            "audienceGated": gated,
            "rule": [
                "priority": 100,
                "trigger": ["any": [["type": "slot_visible", "slots": [slot]]]],
                "conditions": ["all": [Any]()],
            ] as [String: Any],
            "templateConfig": [
                "templateType": "banner",
                "slotKey": slot,
                "image": ["url": "https://cdn.example.com/a.png"],
            ] as [String: Any],
        ]
    }
}
