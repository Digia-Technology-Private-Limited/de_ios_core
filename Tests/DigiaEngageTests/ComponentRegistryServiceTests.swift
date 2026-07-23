import Foundation
import Testing
@testable import DigiaEngage

/// Fake sender that records every call made against `recordComponents` —
/// distinct from `FakeAnalyticsSender` (AnalyticsServiceTests.swift), which
/// only counts calls to the `track` endpoint.
final class FakeComponentSender: AnalyticsSender, @unchecked Sendable {
    private var _callCount = 0
    var callCount: Int { _callCount }
    private(set) var lastBody: [String: Any]?

    func post(url: String, body: Data, headers: [String: String]) async throws -> Int {
        guard url == DigiaEndpoints.recordComponents else { return 200 }
        _callCount += 1
        lastBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
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

    @Test("does nothing when recording mode is disabled")
    func disabledIsNoOp() async throws {
        let (service, sender) = makeService()

        service.recordPage("home")
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(sender.callCount == 0)
    }

    @Test("does nothing on a non-debug build even if enabled")
    func nonDebugBuildIsNoOp() async throws {
        let (service, sender) = makeService(isDebugBuild: false)
        service.setEnabled(true)

        service.recordPage("home")
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(sender.callCount == 0)
    }

    @Test("batches page anchor slot seen within the debounce window into one call")
    func batchesIntoOneCall() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordPage("checkout")
        service.recordAnchor("checkout_cta", screenName: "checkout")
        service.recordSlot("home_banner", screenName: "checkout")

        // Not yet flushed — still inside the debounce window.
        #expect(sender.callCount == 0)

        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(sender.callCount == 1)
        let components = sender.lastBody?["components"] as? [[String: Any]]
        #expect(components?.count == 3)
        let types = Set((components ?? []).compactMap { $0["componentType"] as? String })
        #expect(types == ["page", "anchor", "slot"])
    }

    @Test("dedupes repeated mounts of the same key within a session")
    func dedupesWithinSession() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordPage("home")
        try await Task.sleep(nanoseconds: 900_000_000)
        service.recordPage("home") // remount
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(sender.callCount == 1)
    }

    @Test("drops an anchor with no current screen name")
    func dropsAnchorWithoutScreen() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordAnchor("checkout_cta", screenName: nil)
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(sender.callCount == 0)
    }

    @Test("drops an invalid componentKey")
    func dropsInvalidKey() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordPage("Not_Valid_Key")
        service.recordPage("valid_key")
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(sender.callCount == 1)
        let components = sender.lastBody?["components"] as? [[String: Any]]
        #expect(components?.count == 1)
        #expect(components?.first?["componentKey"] as? String == "valid_key")
    }

    @Test("turning recording mode off cancels a pending flush")
    func disablingCancelsPendingFlush() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordPage("home")
        service.setEnabled(false)
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(sender.callCount == 0)
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

    @Test("flush is a safety net for a still-pending debounce timer")
    func flushIsSafetyNet() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordPage("home")
        await service.flush() // e.g. called from the didEnterBackground observer

        #expect(sender.callCount == 1)
    }
}
