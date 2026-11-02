import Foundation
import Testing

@testable import DigiaEngage

/// A bundle every test below reads from.
private func firstOpenBundle(_ triggers: [String: [String: Any]]) -> NetworkResponse {
    let campaigns = triggers.map { key, trigger -> [String: Any] in
        [
            "id": "id-\(key)",
            "campaignKey": key,
            "campaignType": "nudge",
            "status": "active",
            "rule": [
                "priority": 600,
                "trigger": ["any": [trigger]],
                "conditions": ["all": [["type": "device", "key": "app_opens", "op": "eq", "value": 1]]],
            ] as [String: Any],
            "templateConfig": [
                "templateType": "nudge",
                "layoutMode": "canvas",
                "container": ["displayType": "dialog"],
                "canvas": ["version": 2, "canvasWidth": 320, "canvasHeight": 200, "children": [Any]()],
                "variables": [Any](),
            ] as [String: Any],
        ]
    }
    let body = try! JSONSerialization.data(withJSONObject: ["campaigns": campaigns])
    return NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true)
}

private final class OpensSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []
    var records: [TimelineRecord] { lock.withLock { stored } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
}

/// One phone: the defaults carry over between cold starts.
@MainActor
private struct Phone {
    let defaults = UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
    let legacy = UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!

    var storedCount: Int? {
        defaults.object(forKey: AppOpensCounter.storageKey) as? Int
    }

    func coldStart(
        _ triggers: [String: [String: Any]], inBackground: Bool = false
    ) async throws -> SDKInstance {
        let network = HeldBundleNetworkClient()
        network.release(.success(firstOpenBundle(triggers)))
        let sdk = SDKInstance(defaults: defaults, legacyDefaults: legacy, makeNetworkClient: { _ in network })
        sdk.launchedInBackground = { inBackground }
        try await sdk.initialize(DigiaConfig(apiKey: "test-api-key"))
        for _ in 0..<300 where sdk.sdkState != .ready { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(sdk.sdkState == .ready)
        return sdk
    }
}

/// Flutter: `test/dmc_app_opens_test.dart` — DMC spec S1 and §3.7:
/// `device.app_opens` counts cold starts on the phone.
@MainActor
@Suite("DMC app opens through SDKInstance", .serialized)
struct DMCAppOpensTests {
    @Test("counts cold starts, not foregrounds")
    func countsColdStarts() async throws {
        let phone = Phone()
        let sink = OpensSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        let triggers: [String: [String: Any]] = [
            "welcome": ["type": "app_opened"],
            "welcome_back": ["type": "app_foregrounded"],
        ]

        let first = try await phone.coldStart(triggers)
        #expect(first.controller.activeNudge?.payload.campaignKey == "welcome")
        #expect(phone.storedCount == 1)
        first.controller.dismissNudge()

        // A return to the foreground is not an open: the count is still 1.
        first.appDidEnterBackground()
        first.appWillEnterForeground()
        #expect(first.controller.activeNudge?.payload.campaignKey == "welcome_back")
        #expect(phone.storedCount == 1)
        first.controller.dismissNudge()

        let second = try await phone.coldStart(triggers)
        #expect(second.controller.activeNudge == nil)
        #expect(phone.storedCount == 2)
        #expect(
            sink.records.contains {
                $0.campaignKey == "welcome" && $0.reason?.wire == TimelineReason.conditionFailed.wire
            })
    }
}

/// Flutter: `test/dmc_background_launch_test.dart` — DMC spec §6.2: a process
/// launched while the phone is asleep defers the open until the app returns.
@MainActor
@Suite("DMC background launch", .serialized)
struct DMCBackgroundLaunchTests {
    @Test("a launch in the background counts the open on return")
    func backgroundLaunchCountsOnReturn() async throws {
        let phone = Phone()

        let sdk = try await phone.coldStart(["welcome": ["type": "app_opened"]], inBackground: true)

        // Not on screen yet: neither the open nor the campaign it earns has
        // happened, so the counter was never written.
        #expect(sdk.controller.activeNudge == nil)
        #expect(phone.storedCount == nil)

        sdk.appWillEnterForeground()

        #expect(sdk.controller.activeNudge?.payload.campaignKey == "welcome")
        #expect(phone.storedCount == 1)
    }
}
