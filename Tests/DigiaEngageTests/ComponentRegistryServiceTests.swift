import Foundation
import Testing
@testable import DigiaEngage

/// Fake sender that records every call made against `recordComponents` —
/// distinct from `FakeAnalyticsSender` (AnalyticsServiceTests.swift), which
/// only counts calls to the `track` endpoint.
///
/// Guarded, because the service sends fire-and-forget from one unstructured
/// `Task` per component: three concurrent `post`s racing on a plain `Array`
/// lose appends, and how often depends on how long each task takes — which is
/// not something a test should be asserting on.
final class FakeComponentSender: AnalyticsSender, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _bodies: [[String: Any]] = []

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    var bodies: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return _bodies
    }

    func post(url: String, body: Data, headers: [String: String]) async throws -> Int {
        guard url == DigiaEndpoints.recordComponents else { return 200 }
        record(try? JSONSerialization.jsonObject(with: body) as? [String: Any])
        return 200
    }

    /// Synchronous on purpose: `NSLock` is unavailable from an async context.
    private func record(_ parsed: [String: Any]?) {
        lock.lock()
        _callCount += 1
        if let parsed { _bodies.append(parsed) }
        lock.unlock()
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
        defaults: UserDefaults? = nil,
        debugOverlay: DigiaDebugOverlayController? = nil
    ) -> (ComponentRegistryService, FakeComponentSender) {
        let service = ComponentRegistryService(
            defaults: defaults ?? makeDefaults(),
            sender: sender,
            debugOverlay: debugOverlay
        )
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

    @Test("recordedThisSession lists each newly-seen key once, in order")
    func recordedThisSessionListsDistinctKeys() async throws {
        let (service, _) = makeService()
        service.setEnabled(true)

        service.recordPage("checkout")
        service.recordAnchor("checkout_cta", screenName: "checkout")
        service.recordPage("checkout") // remount, same key — must not duplicate
        try await settle()

        let entries = service.recordedThisSession
        #expect(entries.count == 2)
        #expect(entries[0].type == "page")
        #expect(entries[0].key == "checkout")
        #expect(entries[1].type == "anchor")
        #expect(entries[1].key == "checkout_cta")
        #expect(entries[1].screenName == "checkout")
    }

    @Test("turning recording on shows the debug bubble automatically")
    func enablingRecordingShowsBubble() async throws {
        let overlay = DigiaDebugOverlayController(defaults: makeDefaults())
        let (service, _) = makeService(debugOverlay: overlay)
        #expect(!overlay.isVisible)

        service.setEnabled(true)

        #expect(overlay.isVisible)
    }

    @Test("turning recording off does not hide the debug bubble")
    func disablingRecordingDoesNotHideBubble() async throws {
        let overlay = DigiaDebugOverlayController(defaults: makeDefaults())
        let (service, _) = makeService(debugOverlay: overlay)
        service.setEnabled(true)

        service.setEnabled(false)

        #expect(overlay.isVisible)
    }

    @Test("holds an anchor with no screen until the first screen is set")
    func buffersAnchorUntilScreen() async throws {
        let (service, sender) = makeService()
        service.setEnabled(true)

        service.recordAnchor("checkout_cta", screenName: nil)
        try await settle()

        #expect(sender.callCount == 0)

        service.recordPage("checkout")
        service.attachPendingAnchors(to: "checkout")
        try await settle()

        #expect(sender.callCount == 2)
        let components = sender.bodies.compactMap { ($0["components"] as? [[String: Any]])?.first }
        let anchor = components.first(where: { $0["componentType"] as? String == "anchor" })
        #expect(anchor?["componentKey"] as? String == "checkout_cta")
        #expect(anchor?["screenName"] as? String == "checkout")
    }

    @Test("holds an anchor seen before configure and records it after")
    func buffersAnchorUntilConfigured() async throws {
        let sender = FakeComponentSender()
        let defaults = makeDefaults()
        defaults.set(true, forKey: "digia_component_registry_recording_enabled")
        let service = ComponentRegistryService(defaults: defaults, sender: sender)

        service.recordAnchor("tab_home", screenName: nil)
        service.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1", isDebugBuild: true)
        service.attachPendingAnchors(to: "home")
        try await settle()

        #expect(sender.callCount == 1)
        let anchor = (sender.bodies.last?["components"] as? [[String: Any]])?.first
        #expect(anchor?["componentKey"] as? String == "tab_home")
        #expect(anchor?["screenName"] as? String == "home")
    }

    @Test("does not buffer when recording is off")
    func noBufferWhenDisabled() async throws {
        let (service, sender) = makeService() // configured, recording off

        service.recordAnchor("checkout_cta", screenName: nil)
        service.setEnabled(true)
        service.attachPendingAnchors(to: "checkout")
        try await settle()

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
}
