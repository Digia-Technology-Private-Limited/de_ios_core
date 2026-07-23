import Foundation
import Testing
@testable import DigiaEngage

/// Fake sender that records every call made against `recordComponents` —
/// distinct from `FakeAnalyticsSender` (AnalyticsServiceTests.swift), which
/// only counts calls to the `track` endpoint.
final class FakeComponentSender: AnalyticsSender, @unchecked Sendable {
    private var _callCount = 0
    var callCount: Int { _callCount }
    private(set) var bodies: [[String: Any]] = []

    func post(url: String, body: Data, headers: [String: String]) async throws -> Int {
        guard url == DigiaEndpoints.recordComponents else { return 200 }
        _callCount += 1
        if let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            bodies.append(parsed)
        }
        return 200
    }
}

@MainActor
@Suite("ComponentRegistryService", .serialized)
struct ComponentRegistryServiceTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
    }

    private func makeService(
        sender: FakeComponentSender = FakeComponentSender(),
        isDebugBuild: Bool = true,
        defaults: UserDefaults? = nil
    ) -> (ComponentRegistryService, FakeComponentSender) {
        let service = ComponentRegistryService(defaults: defaults ?? makeDefaults(), sender: sender)
        service.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1", isDebugBuild: isDebugBuild)
        return (service, sender)
    }

    /// Fire-and-forget sends run on an unstructured Task, so tests give it a
    /// short beat to complete rather than awaiting it directly.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    @Test("does nothing when recording mode is disabled")
    func disabledIsNoOp() async throws {
        let (service, sender) = makeService()

        service.recordPage("home")
        try await settle()

        #expect(sender.callCount == 0)
    }

    @Test("does nothing on a non-debug build even if enabled")
    func nonDebugBuildIsNoOp() async throws {
        let (service, sender) = makeService(isDebugBuild: false)
        service.setEnabled(true)

        service.recordPage("home")
        try await settle()

        #expect(sender.callCount == 0)
    }

    @Test("fires one request immediately per newly-seen key")
    func firesOneRequestPerKey() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordPage("checkout")
        service.recordAnchor("checkout_cta", screenName: "checkout")
        service.recordSlot("home_banner", screenName: "checkout")
        try await settle()

        #expect(sender.callCount == 3)
        for body in sender.bodies {
            let components = body["components"] as? [[String: Any]]
            #expect(components?.count == 1)
        }
        let types = Set(sender.bodies.compactMap {
            ($0["components"] as? [[String: Any]])?.first?["componentType"] as? String
        })
        #expect(types == ["page", "anchor", "slot"])
    }

    @Test("dedupes repeated mounts of the same key within a session")
    func dedupesWithinSession() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordPage("home")
        service.recordPage("home") // remount, same key
        try await settle()

        #expect(sender.callCount == 1)
    }

    @Test("drops an anchor with no current screen name")
    func dropsAnchorWithoutScreen() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordAnchor("checkout_cta", screenName: nil)
        try await settle()

        #expect(sender.callCount == 0)
    }

    @Test("drops an invalid componentKey")
    func dropsInvalidKey() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordPage("Not_Valid_Key")
        service.recordPage("valid_key")
        try await settle()

        #expect(sender.callCount == 1)
        let components = sender.bodies.first?["components"] as? [[String: Any]]
        #expect(components?.first?["componentKey"] as? String == "valid_key")
    }

    @Test("persists the toggle across configure calls")
    func persistsToggle() async throws {
        let defaults = makeDefaults()
        let (service, _) = makeService(defaults: defaults)
        service.setEnabled(true)

        let reconfigured = ComponentRegistryService(defaults: defaults, sender: FakeComponentSender())
        reconfigured.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1", isDebugBuild: true)

        #expect(reconfigured.isEnabled)
    }
}
