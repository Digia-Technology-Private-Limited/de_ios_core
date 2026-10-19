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

private final class ManualClock {
    var now = 1_000
}

private func rule(priority: Int, screen: String, wait: Any? = nil) -> [String: Any] {
    var rule: [String: Any] = [
        "priority": priority,
        "trigger": ["any": [["type": "screen_viewed", "names": [screen]]]],
        "conditions": ["all": [Any]()],
    ]
    if let wait { rule["wait"] = wait }
    return rule
}

private func nudge(
    _ key: String, _ priority: Int, screen: String = "login", wait: Any? = nil,
    rule customRule: [String: Any]? = nil, extra: [String: Any] = [:]
) -> [String: Any] {
    var json: [String: Any] = [
        "id": "id-\(key)", "campaignKey": key, "campaignType": "nudge", "status": "active",
        "rule": customRule ?? rule(priority: priority, screen: screen, wait: wait),
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

/// Flutter: `test/dmc_rule_wait_test.dart`, group "SDKInstance" — waits through the whole SDK,
/// with the wait clock moved by hand.
@MainActor
@Suite("DMC rule wait (SDKInstance)", .serialized)
struct DMCRuleWaitSDKTests {
    private let clock = ManualClock()
    private let sink = WaitSink()

    private let loginWait = nudge(
        "login_tip", 900,
        wait: [
            "type": "delay", "ms": 20_000,
            "cancel": ["any": [["type": "event", "name": "login_submitted"], ["type": "screen_left"]]],
        ] as [String: Any])

    /// Boots an SDK; `hold` leaves the bundle request unanswered and returns the release.
    private func boot(_ campaigns: [[String: Any]], hold: Bool = false) async throws -> (SDKInstance, () -> Void) {
        let network = HeldBundleNetworkClient()
        let body = try JSONSerialization.data(withJSONObject: ["campaigns": campaigns])
        let response = Result<NetworkResponse, Error>.success(
            NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true))
        let sdk = SDKInstance(
            defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { _ in network })
        sdk.waitClock = { [clock] in clock.now }
        DigiaLogger.registerSink(sink)
        try await sdk.initialize(DigiaConfig(apiKey: "test-api-key"))
        let release = { network.release(response) }
        if !hold {
            release()
            try await waitReady(sdk)
        }
        return (sdk, release)
    }

    private func waitReady(_ sdk: SDKInstance) async throws {
        for _ in 0..<300 where sdk.sdkState != .ready { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(sdk.sdkState == .ready)
    }

    private func advance(_ sdk: SDKInstance, ms: Int) {
        clock.now += ms
        sdk.engine.waits.schedule()
    }

    private func withReason(_ key: String, _ reason: TimelineReason) -> [TimelineRecord] {
        sink.records.filter { $0.campaignKey == key && $0.reason?.wire == reason.wire }
    }

    private func busyDrops(_ key: String) -> [TimelineRecord] {
        sink.records.filter { $0.campaignKey == key && $0.reason?.wire == DropReason.surfaceBusy.wire }
    }

    private func shown(_ sdk: SDKInstance) -> String? { sdk.controller.activeNudge?.payload.campaignKey }

    @Test("shows only after the wait")
    func showsAfterWait() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, _) = try await boot([loginWait])

        sdk.setCurrentScreen("login")
        #expect(shown(sdk) == nil)
        #expect(withReason("login_tip", .waitStarted).count == 1)

        advance(sdk, ms: 19_999)
        #expect(shown(sdk) == nil)
        advance(sdk, ms: 1)
        #expect(shown(sdk) == "login_tip")
        #expect(withReason("login_tip", .waitEnded).first?.extras == ["outcome": "checked"])
        sdk.controller.dismissNudge()
    }

    @Test("a cancel event stops the show")
    func cancelEventStopsShow() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, _) = try await boot([loginWait])

        sdk.setCurrentScreen("login")
        sdk.trackEvent("login_submitted")
        advance(sdk, ms: 20_000)

        #expect(shown(sdk) == nil)
        #expect(withReason("login_tip", .waitCancelled).first?.extras == ["cause": "event"])
    }

    @Test("a cancel event acts before its analytics write ends")
    func cancelActsBeforeWrite() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, _) = try await boot([loginWait])

        sdk.setCurrentScreen("login")
        sdk.trackEvent("login_submitted")

        // trackEvent returned synchronously; the analytics write is queued behind it.
        #expect(withReason("login_tip", .waitCancelled).count == 1)
    }

    @Test("leaving the screen stops the show; a repeat does not")
    func leavingScreenStopsShow() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, _) = try await boot([loginWait])

        sdk.setCurrentScreen("login")
        sdk.setCurrentScreen("login")
        #expect(withReason("login_tip", .waitInProgress).count == 1)
        #expect(withReason("login_tip", .waitCancelled).isEmpty)

        sdk.setCurrentScreen("home")
        advance(sdk, ms: 20_000)
        #expect(shown(sdk) == nil)
        #expect(withReason("login_tip", .waitCancelled).first?.extras == ["cause": "screen_left"])
    }

    @Test("a wait keeps running in the background and shows on return")
    func waitRunsInBackground() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, _) = try await boot([loginWait])

        sdk.setCurrentScreen("login")
        advance(sdk, ms: 12_000)
        sdk.appDidEnterBackground()
        clock.now += 180_000
        #expect(shown(sdk) == nil)

        sdk.appWillEnterForeground()
        #expect(shown(sdk) == "login_tip")
        sdk.controller.dismissNudge()
    }

    @Test("a user change ends the wait")
    func userChangeEndsWait() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, _) = try await boot([loginWait])

        sdk.setCurrentScreen("login")
        sdk.setUserId("user-2")
        advance(sdk, ms: 20_000)

        #expect(shown(sdk) == nil)
        #expect(withReason("login_tip", .waitCancelled).first?.extras == ["cause": "session_ended"])
    }

    @Test("a session end drops an anchor seen before ready")
    func sessionEndDropsHeldAnchor() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let anchorRule: [String: Any] = [
            "priority": 600,
            "trigger": ["any": [["type": "anchor_visible", "keys": ["cta"]]]],
            "conditions": ["all": [Any]()],
        ]
        let (sdk, release) = try await boot([nudge("cta_tip", 600, rule: anchorRule)], hold: true)

        sdk.recordAnchorSeen("cta")
        try await Task.sleep(nanoseconds: 50_000_000)
        try #require(sdk.services).sessionManager.reset()
        release()
        try await waitReady(sdk)

        #expect(shown(sdk) == nil)
    }

    @Test("a no-wait winner shows now; waits of the trigger start too")
    func noWaitWinnerShowsNow() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, _) = try await boot([
            nudge("pharmacist", 900, wait: ["type": "delay", "ms": 5_000]),
            nudge("product_of_day", 800),
            nudge("login_also", 700),
        ])

        sdk.setCurrentScreen("login")
        #expect(shown(sdk) == "product_of_day")
        #expect(withReason("pharmacist", .waitStarted).count == 1)
        #expect(withReason("login_also", .lowerPriority).count == 1)

        advance(sdk, ms: 5_000)
        #expect(shown(sdk) == "product_of_day")
        sdk.controller.dismissNudge()
    }

    @Test("a held signal: the no-wait winner shows before an ended wait")
    func heldSignalNoWaitFirst() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, release) = try await boot(
            [nudge("waited_tip", 900, wait: ["type": "delay", "ms": 1_000]), nudge("now_tip", 800)], hold: true)

        sdk.setCurrentScreen("login")
        advance(sdk, ms: 2_000)
        release()
        try await waitReady(sdk)
        advance(sdk, ms: 0)

        #expect(shown(sdk) == "now_tip")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!busyDrops("waited_tip").isEmpty)
        sdk.controller.dismissNudge()
    }

    @Test("of waits ending together, the losers find the surface busy")
    func losersFindSurfaceBusy() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, _) = try await boot([
            nudge("high_tip", 900, wait: ["type": "delay", "ms": 1_000]),
            nudge("low_tip", 800, wait: ["type": "delay", "ms": 1_000]),
        ])

        sdk.setCurrentScreen("login")
        advance(sdk, ms: 1_000)

        #expect(shown(sdk) == "high_tip")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(busyDrops("low_tip").count == 1)
        #expect(withReason("low_tip", .lowerPriority).isEmpty)
        sdk.controller.dismissNudge()
    }

    @Test("the cap is checked again when the wait ends")
    func capRecheckedAtWaitEnd() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, _) = try await boot([
            nudge("capped_tip", 900, wait: ["type": "delay", "ms": 1_000], extra: ["frequency": ["maxTotal": 1]])
        ])

        sdk.setCurrentScreen("login")
        let services = try #require(sdk.services)
        let capped = try #require(sdk.campaignStore.find("capped_tip"))
        services.frequencyManager.recordShow("capped_tip", capped.frequency)
        advance(sdk, ms: 1_000)

        #expect(shown(sdk) == nil)
        #expect(withReason("capped_tip", .capped).count == 1)
    }

    @Test("waits run in parallel; a later end finds the surface busy")
    func parallelWaits() async throws {
        defer { DigiaLogger.unregisterSink(sink) }
        let (sdk, _) = try await boot([
            nudge("login_tip", 900, wait: ["type": "delay", "ms": 1_000]),
            nudge("home_tip", 800, screen: "home", wait: ["type": "delay", "ms": 2_000]),
        ])

        sdk.setCurrentScreen("login")
        sdk.setCurrentScreen("home")
        #expect(withReason("home_tip", .waitStarted).count == 1)

        advance(sdk, ms: 1_000)
        #expect(shown(sdk) == "login_tip")
        advance(sdk, ms: 1_000)
        #expect(shown(sdk) == "login_tip")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!busyDrops("home_tip").isEmpty)
        sdk.controller.dismissNudge()
    }
}
